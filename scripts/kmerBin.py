#!/usr/bin/env python
#to do: gpu support https://github.com/rapidsai/cuml

import numpy as np
import umap
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import pandas as pd
import hdbscan
import argparse
import os

def parse_arguments():
    """Read arguments from the console"""
    parser = argparse.ArgumentParser(description="Note: umap cluster with hdbscan.")
    parser.add_argument("-k", "--kmer", help='kmer file from kmer_freqs.py')
    parser.add_argument("-n", "--n_neighbors", help='n_neighbors for UMAP', default=50)
    parser.add_argument("-d", "--min_dist", help='min_dist for UMAP', default=0.1)
    parser.add_argument("-r", "--metric", help='metric for UMAP', default='euclidean')
    parser.add_argument("-l", "--low_memory", help='low_memory for UMAP', action="store_true", default=False)
    parser.add_argument("-t", "--n_components", help='n_components for UMAP', default=2)
    parser.add_argument("-s", "--min_cluster_size", help='min_cluster_size for HDBSCAN', default=10)
    parser.add_argument("-m", "--min_samples", help='min_samples for HDBSCAN', default=10)
    parser.add_argument("-e", "--epsilon", help='cluster selection epsilon (stop spliting)', default=0)
    parser.add_argument("-c", "--cluster", help='export cluster file')
    parser.add_argument("-p", "--plot", help="plot the cluster [TRUE]", action="store_true", default=False)

    args = parser.parse_args()
    return args

def umap_reduction(kmer_freqs, n_neighbors, metric, low_memory, min_dist, n_components):
    df = pd.read_csv(kmer_freqs, delimiter="\t")
    n_neighbors = int(n_neighbors)
    min_dist = float(min_dist)
    n_components = int(n_components)
    #UMAP
    motifs = [x for x in df.columns.values if x not in ["read", "length"]]
    X = df.loc[:,motifs]
    X_embedded = umap.UMAP(
        random_state=123, n_neighbors=n_neighbors, metric=str(metric), low_memory=low_memory,
        min_dist=min_dist, n_components=n_components, verbose=True).fit_transform(X)
    df_umap = pd.DataFrame(X_embedded, columns=["D" + str(x) for x in range(1, n_components + 1)])
    umap_out = pd.concat([df["read"], df["length"], df_umap], axis=1)
    return X_embedded, umap_out

def hdbscan_cluster(umap_out, min_cluster_size, min_samples, cluster_sel_epsilon, n_components):
    min_cluster_size = int(min_cluster_size)
    min_samples = int(min_samples)
    cluster_sel_epsilon = float(cluster_sel_epsilon)
    n_components = int(n_components)
    #HDBSCAN
    X = umap_out.loc[:, ["D" + str(x) for x in range(1, n_components + 1)]]
    umap_out["bin_id"] = hdbscan.HDBSCAN(
        min_cluster_size=min_cluster_size,
        min_samples=min_samples,
        cluster_selection_epsilon=cluster_sel_epsilon).fit_predict(X)
    return umap_out

def plot_cluster(X_embedded, umap_out, plot_out):
    #PLOT
    plt.figure(figsize=(20,20))
    plt.scatter(X_embedded[:, 0], X_embedded[:, 1], c=umap_out["bin_id"], cmap='Spectral', s=1)
    plt.xlabel("UMAP1", fontsize=18)
    plt.ylabel("UMAP2", fontsize=18)
    plt.gca().set_aspect('equal', 'datalim')
    plt.title("Projecting " + str(len(umap_out['bin_id'])) + " reads. " + str(len(umap_out['bin_id'].unique())) + " clusters generated by HDBSCAN", fontsize=18)
    
    for cluster in np.sort(umap_out['bin_id'].unique()):
        read = umap_out.loc[umap_out['bin_id'] == cluster].iloc[0]
        plt.annotate(str(cluster), (read['D1'], read['D2']), weight='bold', size=14)
    plt.savefig(plot_out)

def main():
    args = parse_arguments()
    X_embedded, umap_out1 = umap_reduction(args.kmer, args.n_neighbors, args.metric, args.low_memory, args.min_dist, args.n_components)
    hdbscan_out = hdbscan_cluster(umap_out1, args.min_cluster_size, args.min_samples, args.epsilon, args.n_components)
    if args.plot:
        plot_cluster(X_embedded, hdbscan_out, plot_out=os.path.splitext(args.cluster)[0] + ".png")
    hdbscan_out.to_csv(args.cluster, sep="\t", index=False)

if __name__ == "__main__":
    main()

