function [Basis,Coeff] = tsvdnmf(A,outpath,K)
%************ Thresolded SVD based provable NMF method based on "NMF under Heavy Noise (ICML  2016)"*************
% 
% Inputs:
% A : data matrix (Columns: data points, Rows: features)
% outpath : Output folder (final basis matrix (Basis) and co-efficient matrix (Coeff) will be written here)
% K : Number of basis vectors
%
% Output:
% Basis : basis matrix
% Coeff: co-efficient matrix
%
% Example:
% load reuters10.mat; %variable A is inside reuters10.mat
% outpath = 'output';
% K = 10;
% [Basis,Coeff] = tsvdnmf(A,outpath,K);
% 
% Note: You have to install sparsesubaccess which has been provided inside
% the .zip file.
%-------------------------------------------------------------------------
% Author: Jagdeep Pani
% Last Modified: June 21, 2016
% I will modify further to improve efficiency.
%-------------------------------------------------------------------------
w0 = 1.0/K;
eps2 = 1/3;
rho = 1.05;
eps3 = 1.1;        
eps5 = 0.04;
alpha5 = 0.9;
beta5 = 0.02;
tolerance = 15;
mkdir(outpath)

[d,n] = size(A);
fprintf('\nNo of data points :%d\n',n);
fprintf('\nNo of feaures :%d\n',d);
if d*n > 1e8
    save(strcat(outpath, '/A.mat'),'A');  % Save A for later use, if its large
end

start_time = tic;

% A = A*spdiags(1./sum(A,1)',0,d,d); %normalized A

fprintf('Thresholding on A\n')
tic;
A = A'; % Row slicing is inefficient for sparse matrix
[B, thres] = threshold_tsvdnmf(A, eps5, alpha5, beta5,tolerance);
toc;
fprintf('Thresholding on A done..\n')

if d*n > 1e8, clear A; % clear to save space
else A = A'; end

%dlmwrite(strcat(outpath,'/Thresholds'),full(thres),'delimiter','\n');
retained_records = find(sum(B,1)~=0);   %Columns which are not completely zero
B = B(:,retained_records);
fprintf('size of B is %d\n',size(B));

%% Computing the K-rank approximation for the matrix B
fprintf('Computing SVD Projection\n')
tic;
if d*n <= 5e7 && d > n
    [~,S,V] = svds(B,K);
    B_k = sparse(S)*V';
    clear S V;
else
    % computing BB^T then finding top eigenvectors!
    BBt = B*B';
    [U,~] = eigs(BBt,[],K,'lm',struct('issym',1));
    clear BBt;
    B_k = U'*B;
    clear U;
end
toc; 
%% K-means on projected matrix
% fprintf('Performing k-means on columns of B_k\n')
%% This is k-means %%
% tic;
% q_best = Inf;
% cluster_id = [];
% for r = 1:reps
%     [~,ini_center] = kmeanspp_ini(B_k,K);
%     [~, c_id, ~,q2,~] = kmeans_fast(B_k,ini_center,2,reps > 1);
%     if q2 < q_best
%         cluster_id = c_id; 
%         q_best = q2;
%     end
% end
% fprintf('Quality:%.4f\n',q_best);
% toc;
% clear B_k ini_center c_id;
%%

%% THIS IS BIRCH
fprintf('Performing BIRCH on columns of B_k\n')
tic;
dlmwrite('../BIRCH/B_k',B_k', 'delimiter',' ','precision','%.6f');
[C, ~,~] = BIRCH(K,K,50,2);
fprintf('Number of clusters:%d\n',size(C,1));
C = C';
[~,cluster_id] = max(bsxfun(@minus,2*real(C'*B_k),dot(C,C,1).'));
clear C B_k
toc;
        
P1 = zeros(K,d);  % Finding centers in original space
for k=1:K
    cols = find(cluster_id==k);
    P1(k,:) = sum(B(:,cols),2)./length(cols);
end
%% Lloyds on B with start from B_k
fprintf('Performing Lloyds on B with centers from B_k clustering\n')
tic;
[~, cluster_assign, ~,q2,~] = kmeans_fast(B,P1,2,0);
clear B cluster_id
% fprintf('Quality:%.4f\n',q2);
toc;
cluster_assign = fill_empty_basis(cluster_assign,K,n);   

if d*n > 1e8, load(strcat(outpath, '/A.mat')); end
%A = A*spdiags(1./sum(A,1)',0,d,d); %normalized A
A1_rowsum = full(sum(A,2));

P2 = zeros(d,K);    % this will be basis matrix without using dominan features
for k=1:K
    cols = retained_records(cluster_assign==k);
    P2(:,k) = sum(A(:,cols),2)./length(cols);
end

% Uncomment following two lines to write clustering info
% tic
%dlmwrite(strcat(outpath,'/P2'),full(P2'),'delimiter',' ','precision','%.6f');
%dlmwrite(strcat(outpath,'/clusterID2'),cluster_assign,'\n');
% 
% fprintf('Time take to write P2 and clusterID2 : %f secs',toc);
%% Find dominant features
fprintf('Finding dominant features\n');
tic;
fractiles = zeros(d,K); % This will store the values g(i,l)

for l=1:K
    if (sum(cluster_assign==l)==0)
        fprintf('There is a basis for which no data points are present');
    end
    T = A(:,retained_records(cluster_assign==l))'; %columns of T are features
    
    % sorting on columns is faster for sparse matrix
    T = sort(T,1,'descend'); % sort cols in descending
    fractiles(:,l) = T(min(max(1,floor(eps2*w0*n/2)),size(T,1)),:);
end
clear T;

dom_feat = false(d,K);
for l =1:K
    for i=1:d
        dom_feat(i,l) = false;
        fractile_1 = fractiles(i,l);
        isanchor = false;
        for l2 = 1:K
            if (l2==l), continue; end
            fractile_2 = fractiles(i,l2);
            isanchor = (fractile_1 > rho*fractile_2);
            if ~isanchor
                break
            end
        end
        if isanchor
            dom_feat(i,l)  = true;
        end
    end
end

basis_domf = find(sum(dom_feat,1)~=0);

basis_ndomf = setdiff(1:K,basis_domf);
for l=1:K
    if (~ismember(l,basis_ndomf) && sum(A1_rowsum(dom_feat(:,l))) <= 0.001*n/(2*K))
        basis_ndomf = horzcat(basis_ndomf,l);
    end
end

if ~isempty(basis_ndomf)
    fprintf('Basis with no dominant features: ');
    fprintf('%d ',basis_ndomf); fprintf('\n');
end

% Uncomment the following line to write the dominant feature indicator matrix
% tic;
dlmwrite(strcat(outpath,'/dominant_feat_ind'),full(dom_feat),'delimiter',' ');
% fprintf('Time taken to write dominant feature indicator matrix : %f secs',toc);
Basis = zeros(d,K);
for l=1:K
    if ismember(l,basis_ndomf)
        Basis(:,l) = P2(:,l);
        continue;
    end
    n1 = max(floor(eps3*w0*n/2),1); % new - 08/14
    [~,inds1]=sort(sum(A(dom_feat(:,l),:),1),'descend');
    alpha1 = inds1(1:n1);
    Basis(:,l) = sum(A(:,alpha1),2)*1.0/n1;
end

toc;
end_time = toc(start_time);

Coeff = nnlsHALSupdt(A,Basis);

fprintf('Writing Basis and COefficient matrices\n');
% tic;
dlmwrite(strcat(outpath,'/Basis'),full(Basis'),'delimiter',' ','precision','%.6f');
dlmwrite(strcat(outpath,'/Coeff'),full(Coeff'),'delimiter',' ','precision','%.6f');
% fprintf('Time take to write threshold : %f secs',toc);
fprintf('\nAll Done, algorithm took %.2f seconds\n', end_time);

end

