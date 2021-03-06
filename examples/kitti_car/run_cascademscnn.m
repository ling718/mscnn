% Copyright (c) 2016 The Regents of the University of California
% see mscnn/LICENSE for details
% Written by Zhaowei Cai [zwcai-at-ucsd.edu]
% Please email me if you find bugs, or have suggestions or questions!

clear all; close all;

addpath('../../matlab/'); 
addpath('../../utils/');

root_dir = './cascade-mscnn-7s-576-2x-trainval-pretrained/';
binary_file = [root_dir 'mscnn_kitti_trainval_2nd_iter_35000.caffemodel'];
assert(exist(binary_file, 'file') ~= 0); 
definition_file = [root_dir 'mscnn_deploy.prototxt'];
assert(exist(definition_file, 'file') ~= 0);
use_gpu = true;
if ~use_gpu
  caffe.set_mode_cpu();
else
  caffe.set_mode_gpu(); gpu_id = 0;
  caffe.set_device(gpu_id);
end
net = caffe.Net(definition_file, binary_file, 'test');

% dataset
dataDir = '/your/KITTI/path/';
imgDir = [dataDir 'testing/image_2/'];
obj_names = {'bg','car','van','truck','tram'};
obj_ids = [2]; num_cls=length(obj_ids); 
imgList = dir([imgDir '*.png']); 
nImg=length(imgList);

% architecture
if(~isempty(strfind(root_dir, 'cascade'))), CASCADE = 1;
else CASCADE = 0; end
if (~CASCADE)
  % baseline model
  proposal_blob_names = {'proposals'};
  bbox_blob_names = {'output_bbox_1st'};
  cls_prob_blob_names = {'cls_prob_1st'};
  output_names = {'1st'};
else
  % cascade-rcnn model
  proposal_blob_names = {'proposals_3rd'};
  bbox_blob_names = {'output_bbox_3rd'};
  cls_prob_blob_names = {'cls_prob_3rd'};
  output_names = {'3rd'};
end
num_outputs = numel(proposal_blob_names);
assert(num_outputs==numel(bbox_blob_names));
assert(num_outputs==numel(cls_prob_blob_names));
assert(num_outputs==numel(output_names));

% detection configuration
detect_final_boxes = cell(nImg,num_outputs,num_cls);
det_thr = -1; % threoshold
pNms.type = 'maxg'; pNms.overlap = 0.5; pNms.ovrDnm = 'union'; % NMS

% specify a unique ID if you want to archive the results
comp_id = 'cascade_mscnn_7s_576_2x_35k_test'; 

% image pre-processing
imgW = 1920; imgH = 576;
mu0 = ones(1,1,3); mu0(:,:,1:3) = [104 117 123];

% detection showing setup
show = 0; show_thr = 0.1; usedtime=0; 
if (show)
  fig=figure(1); set(fig,'Position',[-50 100 1350 375]);
  h.axes = axes('position',[0,0,1,1]);
end

for kk = 1:nImg
  img = imread([imgDir imgList(kk).name]);
  orgImg = img;
  if (size(img,3)==1), img = repmat(img,[1 1 3]); end
  [orgH,orgW,~] = size(img);
  
  imgH = round(imgH/32)*32; imgW = round(imgW/32)*32; % must be the multiple of 32
  hwRatios = [imgH imgW]./[orgH orgW];
  img = imresize(img,[imgH imgW]); 
  mu = repmat(mu0,[imgH,imgW,1]);
  img = single(img(:,:,[3 2 1]));
  img = bsxfun(@minus,img,mu);
  img = permute(img, [2 1 3]);

  % network forward
  tic; outputs = net.forward({img}); pertime=toc;
  usedtime=usedtime+pertime; avgtime=usedtime/kk;
    
  for nn = 1:num_outputs
    if (show)
      imshow(orgImg,'parent',h.axes); axis(h.axes,'image','off');
    end
    detect_boxes = cell(num_cls,1); 
    tmp = squeeze(net.blobs(bbox_blob_names{nn}).get_data()); 
    tmp = tmp'; tmp = tmp(:,2:end);
    tmp(:,[1,3]) = tmp(:,[1,3])./hwRatios(2);
    tmp(:,[2,4]) = tmp(:,[2,4])./hwRatios(1);
    % clipping bbs to image boarders
    tmp(:,[1,2]) = max(0,tmp(:,[1,2]));
    tmp(:,3) = min(tmp(:,3),orgW); tmp(:,4) = min(tmp(:,4),orgH);
    tmp(:,[3,4]) = tmp(:,[3,4])-tmp(:,[1,2])+1;
    output_bboxs = double(tmp);  
    
    tmp = squeeze(net.blobs(cls_prob_blob_names{nn}).get_data()); 
    cls_prob = tmp'; 
    
    tmp = squeeze(net.blobs(proposal_blob_names{nn}).get_data());
    tmp = tmp'; tmp = tmp(:,2:end); 
    tmp(:,[3,4]) = tmp(:,[3,4])-tmp(:,[1,2])+1; 
    proposals = tmp;
    
    keep_id = find(proposals(:,3)~=0 & proposals(:,4)~=0);
    proposals = proposals(keep_id,:); 
    output_bboxs = output_bboxs(keep_id,:); cls_prob = cls_prob(keep_id,:);

    for i = 1:num_cls
      id = obj_ids(i);        
      prob = cls_prob(:,id);         
      bbset = double([output_bboxs prob]);
      if (det_thr>0)
        keep_id = find(prob>=det_thr); bbset = bbset(keep_id,:);
      end
      bbset=bbNms(bbset,pNms);
      detect_final_boxes{kk,nn,i} = [ones(size(bbset,1),1)*kk bbset(:,1:5)];
        
      if (show) 
        bbs_show = zeros(0,6);
        if (size(bbset,1)>0) 
          show_id = find(bbset(:,5)>=show_thr);
          bbs_show = bbset(show_id,:);
        end
        for j = 1:size(bbs_show,1)
          rectangle('Position',bbs_show(j,1:4),'EdgeColor','y','LineWidth',2);
          show_text = sprintf('%s=%.2f',obj_names{id},bbs_show(j,5));
          x = bbs_show(j,1)+0.5*bbs_show(j,3);
          text(x,bbs_show(j,2),show_text,'color','r', 'BackgroundColor','k',...
              'HorizontalAlignment','center', 'VerticalAlignment','bottom',...
              'FontWeight','bold', 'FontSize',8);
        end  
      end 
    end  
  end
  if (mod(kk,100)==0), fprintf('idx %i/%i, avgtime=%.4fs\n',kk,nImg,avgtime); end
end

% saving results
save_dir = 'detections/';
if (~exist(save_dir)), mkdir(save_dir); end
for nn = 1:num_outputs
  for j=1:num_cls
    id = obj_ids(j);
    resFile = sprintf('detections/%s_%s_%s_results.txt',comp_id,obj_names{id},output_names{nn});
    save_detect_boxes=cell2mat(detect_final_boxes(:,nn,j));
    dlmwrite(resFile,save_detect_boxes);
  end
end

caffe.reset_all();
