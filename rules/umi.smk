# linker and primer info
flinker = config["flinker"]
fprimers = config["fprimer"]
rlinker = config["rlinker"]
rprimers = config["rprimer"]

# reverse complementation
def revcomp(seq):
    return seq.translate(str.maketrans('ACGTacgtRYMKrymkVBHDvbhd', 'TGCAtgcaYRKMyrkmBVDHbvdh'))[::-1]
flinkerR = revcomp(flinker)
rlinkerR = revcomp(rlinker)
fprimersR = {k: revcomp(v) for k, v in fprimers.items()}
rprimersR = {k: revcomp(v) for k, v in rprimers.items()}

# pattern search for umi using cutadapt
# nanopore possibly sequences either strand
def seqs_join(linker, primer, reverse=False):
    joined = '-g ' + linker + '...' + primer
    if reverse:
        joined = '-G ' + primer + '...' + linker
    return joined
def linked_pattern(linker, primers,reverse=False):
    linked = {k: seqs_join(linker, v, reverse) for k, v in primers.items()}        
    return ' '.join(v for v in linked.values())

# forward
f_pattern1 = linked_pattern(flinker, fprimers)
f_pattern2 = linked_pattern(rlinker, rprimers)
f_pattern = f_pattern1 + ' ' + f_pattern2
# reverse
r_pattern1 = linked_pattern(flinkerR, fprimersR, reverse=True)
r_pattern2 = linked_pattern(rlinkerR, rprimersR, reverse=True)
r_pattern = r_pattern1 + ' ' + r_pattern2
#---------

# indepent qfilt (qc.smk trims the primer together with linker and umi)
use rule q_filter as qfilter_umi with:
    input:
        get_raw(config["subsample"], config["seqkit"]["p"], config["seqkit"]["n"])
    output:
        OUTPUT_DIR + "/umi/{barcode}/qfilt.fastq"
    params:
        Q = config["umi"]["seqkit"]["min-qual"],
        m = config["umi"]["seqkit"]["min-len"],
        M = config["umi"]["seqkit"]["max-len"],
    log:
        OUTPUT_DIR + "/logs/umi/{barcode}/qfilter.log"
    benchmark: 
        OUTPUT_DIR + "/benchmarks/umi/{barcode}/qfilter.txt"
    threads:
        config["threads"]["large"]

# kmer calculation
use rule kmer_freqs as kmer_freqs_umi with:
    input: 
        OUTPUT_DIR + "/umi/{barcode}/qfilt.fastq"
    output: 
        OUTPUT_DIR + "/umi/{barcode}/kmerBin/kmer_freqs.txt"
    log: 
        OUTPUT_DIR + "/logs/{barcode}/kmerBin/kmer_freqs.log"
    benchmark: 
        OUTPUT_DIR + "/benchmarks/{barcode}/kmerBin/kmer_freqs.txt"

# kmer binning
use rule umap as umap_umi with:
    input: 
        rules.kmer_freqs_umi.output
    output: 
        cluster=OUTPUT_DIR + "/umi/{barcode}/kmerBin/hdbscan.tsv",
	      plot=OUTPUT_DIR + "/umi/{barcode}/kmerBin/hdbscan.png",
    log: 
        OUTPUT_DIR + "/logs/umi/{barcode}/kmerBin/umap.log"
    benchmark: 
        OUTPUT_DIR + "/benchmarks/umi/{barcode}/kmerBin/umap.txt"
    
# split reads by cluster
checkpoint cluster_info_umi:
    input: rules.umap_umi.output.cluster,
    output: directory(OUTPUT_DIR + "/umi/{barcode}/kmerBin/clusters"),
    log: OUTPUT_DIR + "/logs/umi/{barcode}/kmerBin/clusters.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/kmerBin/clusters.txt"
    run:
        import pandas as pd
        df = pd.read_csv(input[0], sep="\t")
        df = df[["read", "bin_id"]]
        clusters = df.bin_id.max()
        os.makedirs(output[0])
        for cluster in range(0, clusters+1):
            df.loc[df.bin_id == cluster, "read"].to_csv(output[0] + "/c" + str(cluster) + ".txt", sep="\t", header=False, index=False)
        
use rule split_by_cluster as split_by_cluster_umi with:
    input: 
        clusters = OUTPUT_DIR + "/{barcode}/kmerBin/clusters/{c}.txt",
        fastq = OUTPUT_DIR + "/umi/{barcode}/qfilt.fastq",
    output: 
        OUTPUT_DIR + "/umi/{barcode}/kmerBin/clusters/{c}.fastq",
    log: 
        OUTPUT_DIR + "/logs/umi/{barcode}/kmerBin/clusters/{c}.log"
    benchmark: 
        OUTPUT_DIR + "/benchmarks/umi/{barcode}/kmerBin/clusters/{c}.txt"

use rule skip_bin as skip_bin_umi with:
    input: 
        OUTPUT_DIR + "/umi/{barcode}/qfilt.fastq"
    output: 
        OUTPUT_DIR + "/umi/{barcode}/kmerBin/clusters/all.fastq"
    log: 
        OUTPUT_DIR + "/logs/umi/{barcode}/kmerBin/clusters/skip_bin.log"

def get_fq4Con_umi(kmerbin = True):
    check_val("kmerbin", kmerbin, bool)
    if kmerbin == True:
        out = rules.split_by_cluster_umi.output
    else:
        out = rules.skip_bin_umi.output
    return out

# trim umi region
rule umi_loc:
    input: get_fq4Con(config["kmerbin"])
    output:
        start = OUTPUT_DIR + "/umi/{barcode}/{c}/start.fastq",
        end = OUTPUT_DIR + "/umi/{barcode}/{c}/end.fastq",
    conda: "../envs/seqkit.yaml"
    params:
        umi_loc=config["umi"]["loc"]
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/umi_loc.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/umi_loc.txt"
    shell:
        """
        seqkit subseq -r 1:{params.umi_loc} {input} 2> {log} 1> {output.start}
        seqkit subseq -r -{params.umi_loc}:-1 {input} 2>> {log} 1> {output.end}
        """

# extract UMI sequences
# linked primers to ensure a "trusted" umi, and take a more trusted ref with adequate size in cluster
# This is different from the original design due to different UMI settings
# https://github.com/SorenKarst/longread_umi/blob/00302fd34cdf7a5b8722965f3f6c581acbafd70c/scripts/umi_binning.sh#L193
rule extract_umi:
    input:
        start=rules.umi_loc.output.start,
        end=rules.umi_loc.output.end,
    output:
        umi1=OUTPUT_DIR + "/umi/{barcode}/{c}/umi1.fastq",
        umi2=OUTPUT_DIR + "/umi/{barcode}/{c}/umi2.fastq",
    conda: "../envs/cutadapt.yaml"
    params:
        f=f_pattern,
        r=r_pattern,
        max_err=config["umi"]["max_err"],
        min_overlap=config["umi"]["min_overlap"],
        min_len=config["umi"]["len"] - config["umi"]["base_flex"],
        max_len=config["umi"]["len"] + config["umi"]["base_flex"],
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/extract_umi.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/extract_umi.txt"
    threads: config["threads"]["normal"]
    shell:
        "cutadapt "
        "-j {threads} -e {params.max_err} -O {params.min_overlap} "
        "-m {params.min_len} -M {params.max_len} "
        "--discard-untrimmed "
        "{params.f} "
        "{params.r} "
        "-o {output.umi1} -p {output.umi2} "
        "{input.start} {input.end} > {log} 2>&1"

# combine UMI sequences
rule concat_umi:
    input:
        umi1=rules.extract_umi.output.umi1,
        umi2=rules.extract_umi.output.umi2,
    output: OUTPUT_DIR + "/umi/{barcode}/{c}/umi.fasta"
    conda: "../envs/seqkit.yaml"
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/concat_umi.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/concat_umi.txt"
    shell: "seqkit concat {input.umi1} {input.umi2} 2> {log} | seqkit fq2fa -o {output} 2>> {log}"

# cluster UMIs
rule cluster_umi:
    input: rules.concat_umi.output
    output: OUTPUT_DIR + "/umi/{barcode}/{c}/centroid.fasta"
    conda: "../envs/vsearch.yaml"
    params:
        cl_identity = config["umi"]["cl_identity"],
        min_len = 2*(config["umi"]["len"] - config["umi"]["base_flex"]),
        max_len = 2*(config["umi"]["len"] + config["umi"]["base_flex"]),
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/cluster_umi.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/cluster_umi.txt"
    threads: config["threads"]["normal"]
    shell:
        "vsearch "
        "--cluster_fast {input} --clusterout_sort -id {params.cl_identity} "
        "--clusterout_id --sizeout --centroids {output} "
        "--minseqlength {params.min_len} --maxseqlength {params.max_len} "
        "--qmask none --threads {threads} "
        "--strand both > {log} 2>&1"

rule rename_umi_centroid:
    input: rules.cluster_umi.output
    output: OUTPUT_DIR + "/umi/{barcode}/{c}/umi_centroid.fasta"
    conda: "../envs/seqkit.yaml"
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/rename_umi_centroid.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/rename_umi_centroid.txt"
    shell: "seqkit replace -p '^(.+)$' -r 'umi{{nr}}' {input} -o {output} 2> {log}"

# align the trimmed UMI reads to the potential UMIs, which determine the final UMI clusters
def trim_primers(primers, reverse=False):
    if isinstance(primers, str):
        primers = dict(seqs = primers)
    patterns = {k: '-g ' + v for k, v in primers.items()}
    if reverse:
        patterns = {k: '-G ' + v for k, v in primers.items()}
    return ' '.join(v for v in patterns.values())

fprimer1_trim = trim_primers(flinker)
fprimer2_trim = trim_primers(rlinker)
fprimers_trim = fprimer1_trim + ' ' + fprimer2_trim

rprimer1_trim = trim_primers(fprimersR, reverse=True)
rprimer2_trim = trim_primers(rprimersR, reverse=True)
rprimers_trim = rprimer1_trim + ' ' + rprimer2_trim

rule extract_umip:
    input:
        start=rules.umi_loc.output.start,
        end=rules.umi_loc.output.end,
    output:
        umi1=OUTPUT_DIR + "/umi/{barcode}/{c}/umi1p.fastq",
        umi2=OUTPUT_DIR + "/umi/{barcode}/{c}/umi2p.fastq",
    params:
        f=fprimers_trim,
        r=rprimers_trim,
        max_err=config["umi"]["max_err"],
        min_overlap=config["umi"]["min_overlap"],
        min_len=config["umi"]["len"] - config["umi"]["base_flex"],
        max_len=config["umi"]["len"] + config["umi"]["base_flex"],
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/extract_umip.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/extract_umip.txt"
    threads: config["threads"]["normal"]
    shell:
        "cutadapt "
        "-j {threads} -e {params.max_err} -O {params.min_overlap} "
        "-m {params.min_len} -l {params.max_len} "
        "--discard-untrimmed "
        "{params.f} "
        "{params.r} "
        "-o {output.umi1} -p {output.umi2} "
        "{input.start} {input.end} > {log} 2>&1"

rule concat_umip:
    input:
        umi1=rules.extract_umip.output.umi1,
        umi2=rules.extract_umip.output.umi2,
    output: OUTPUT_DIR + "/umi/{barcode}/{c}/umip.fastq"
    conda: "../envs/seqkit.yaml"
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/concat_umip.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/concat_umip.txt"
    shell: "seqkit concat {input.umi1} {input.umi2} -o {output} 2> {log}"

# calculate the UMI cluster size through mapping
# use bwa aln to map the potential UMI reads to the UMI ref, considering the limited length and sensitivity
rule bwa_index:
    input: rules.rename_umi_centroid.output,
    output:
        multiext(OUTPUT_DIR + "/umi/{barcode}/{c}/umi_centroid.fasta", ".amb", ".ann", ".bwt", ".pac", ".sa"),
    conda: "../envs/bwa.yaml"
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/bwa_index.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/bwa_index.txt"
    shell: "bwa index {input} 2> {log}"

rule bwa_aln:
    input:
        rules.bwa_index.output,
        umip = rules.concat_umip.output,
        ref = rules.rename_umi_centroid.output,
    output: OUTPUT_DIR + "/umi/{barcode}/{c}/umip.sai",
    conda: "../envs/bwa.yaml"
    params:
        n = 6,
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/bwa_aln.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/bwa_aln.txt"
    threads: config["threads"]["large"]
    shell: "bwa aln -n {params.n} -t {threads} -N {input.ref} {input.umip} > {output} 2> {log}"

rule bwa_samse:
    input:
        umip = rules.concat_umip.output,
        ref = rules.rename_umi_centroid.output,
        sai = rules.bwa_aln.output,
    output: OUTPUT_DIR + "/umi/{barcode}/{c}/umip.sam",
    conda: "../envs/bwa.yaml"
    params:
        F = 4,
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/bwa_samse.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/bwa_samse.txt"
    shell:
        "bwa samse -n 10000000 {input.ref} {input.sai} {input.umip} 2> {log} | "
        "samtools view -F {params.F} - > {output} 2>> {log}"

rule umi_filter:
    input:
        sam = rules.bwa_samse.output,
        ref = rules.rename_umi_centroid.output,
    output: OUTPUT_DIR + "/umi/{barcode}/{c}/umicf.fa",
    conda: "../envs/umi.yaml"
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/umi_filter.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/umi_filter.txt"
    shell:
        """
        awk \
        -v UMS={input.sam} \
        -v UC={input.ref} \
        '
        (FILENAME == UMS){{
            CLUSTER[$3]++
        }}
        (FILENAME == UC && FNR%2==1){{
          NAME=substr($1,2)
          if (NAME in CLUSTER){{
            if (CLUSTER[NAME]+0 > 2){{
              SIZE=CLUSTER[NAME]
              gsub(";.*", "", NAME)
              print ">" NAME ";size=" SIZE ";"
              getline; print
            }}
          }}
        }}
        ' \
        {input.sam} \
        {input.ref} \
        > {output} 2> {log} 
        """

# rm potential chimera
rule rm_chimera:
    input: rules.umi_filter.output
    output:
        ref = OUTPUT_DIR + "/umi/{barcode}/{c}/umi_ref.txt",
        fa = OUTPUT_DIR + "/umi/{barcode}/{c}/umi_ref.fa",
    conda: "../envs/umi.yaml"
    params:
        umip_len = config["umi"]["len"] + config["umi"]["base_flex"],
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/rm_chimera.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/rm_chimera.txt"
    shell:
        """
        paste <(cat {input} | paste - - ) \
          <(awk '!/^>/{{print}}' {input} | rev | tr ATCG TAGC) |\
          awk 'NR==FNR {{
              #Format columns
              split($1, a, /[>;]/);
              sub("size=", "", a[3]);
              # Extract UMI1 and UMI2 in both orientations
              s1 = substr($2, 1, {params.umip_len});
              s2 = substr($2, {params.umip_len}+1, 2*{params.umip_len});
              s1rc= substr($3, 1, {params.umip_len});
              s2rc= substr($3, {params.umip_len}+1, 2*{params.umip_len});
              # Register UMI1 size if larger than current highest or if empty
              if ((g1n[s1]+0) <= (a[3]+0) || g1n[s1] == ""){{
                g1n[s1] = a[3];
                g1[s1] = a[2];
              }}
              # Register UMI2 size if larger than current highest or if empty
              if ((g2n[s2]+0) <= (a[3]+0) || g2n[s2] == ""){{
                g2n[s2] = a[3];
                g2[s2] = a[2];
              }}
              # Register UMI1rc size if larger than current highest or if empty
              if ((g1n[s1rc]+0) <= (a[3]+0) || g1n[s1rc] == ""){{
                g1n[s1rc] = a[3];
                g1[s1rc] = a[2];
              }}
              # Register UMI2rc size if larger than current highest or if empty
              if ((g2n[s2rc]+0) <= (a[3]+0) || g2n[s2rc] == ""){{
                g2n[s2rc] = a[3];
                g2[s2rc] = a[2];
              }}
              # Register UMI1 and UMI matches for current UMI
              u[a[2]] = a[3];
              s1a[a[2]] = s1;
              s2a[a[2]] = s2;
              s1arc[a[2]] = s1rc;
              s2arc[a[2]] = s2rc;
            }} END {{
              for (i in u){{
                keep="no";
                if (g1[s1a[i]] == i && g2[s2a[i]] == i && g1[s1arc[i]] == i && g2[s2arc[i]] == i && s1a[i] != s1arc[i]){{
                  keep="yes";
                  print ">"i";"u[i]"\\n"s1a[i]s2a[i] > "{output.fa}";
                }} else if (s1a[i] == s1arc[i]){{
                  keep="tandem"
                  print ">"i";"u[i]"\\n"s1a[i]s2a[i] > "{output.fa}";
                }}
                print i, n[i], s1a[i], s2a[i], keep, g1[s1a[i]]"/"g2[s2a[i]]"/"g1[s1arc[i]]"/"g2[s2arc[i]], u[i]
              }}  
            }}' > {output.ref} 2> {log}
        """

# UMI binning
# extract strict UMI region
rule umi_loc2:
    input:
        start = rules.umi_loc.output.start,
        end = rules.umi_loc.output.end,
    output:
        start = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/reads_umi1.fa",
        end = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/reads_umi2.fa",
    conda: "../envs/seqkit.yaml"
    params:
        s = config["umi"]["s"],
        e = config["umi"]["e"],
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/bin/umi_loc2.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/bin/umi_loc2.txt"
    shell:
        """
        seqkit subseq -r 1:{params.s} {input.start} 2> {log} | seqkit fq2fa -o {output.start} 2>> {log}
        seqkit subseq -r -{params.e}:-1 {input.end} 2> {log} | seqkit fq2fa -o {output.end} 2>> {log}
        """

# split UMI ref to capture UMI in both orientations
rule split_umi_ref:
    input: rules.rm_chimera.output.fa
    output:
        umi1=OUTPUT_DIR + "/umi/{barcode}/{c}/bin/barcodes_umi1.fa",
        umi2=OUTPUT_DIR + "/umi/{barcode}/{c}/bin/barcodes_umi2.fa",
    conda: "../envs/umi.yaml"
    params:
        umi_len = config["umi"]["len"] + config["umi"]["base_flex"],
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/bin/split_umi_ref.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/bin/split_umi_ref.txt"
    shell:
        """
        cat {input} <(seqtk seq -r {input} |\
          awk 'NR%2==1{{print $0 "_rc"; getline; print}};') |\
          awk 'NR%2==1{{
               print $0 > "{output.umi1}";
               print $0 > "{output.umi2}";  
             }}
             NR%2==0{{
               print substr($0, 1, {params.umi_len}) > "{output.umi1}";
               print substr($0, length($0) - {params.umi_len} + 1, {params.umi_len})  > "{output.umi2}";  
             }}'
        """

# Map UMI barcode to regions containing UMI
## Important settings:
## -N : diasble iterative search. All possible hits are found.
## -F 20 : Removes unmapped and reverse read matches. Keeps UMIs
##         in correct orientations.
use rule bwa_index as index_umi with:
    input:
        ref = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/reads_{umi}.fa",
    output:
        multiext(OUTPUT_DIR + "/umi/{barcode}/{c}/bin/reads_{umi}.fa", ".amb", ".ann", ".bwt", ".pac", ".sa"),
    log:
        OUTPUT_DIR + "/logs/umi/{barcode}/{c}/bin/index_{umi}.log"
    benchmark:
        OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/bin/index_{umi}.txt"

use rule bwa_aln as aln_umi with:
    input:
        multiext(OUTPUT_DIR + "/umi/{barcode}/{c}/bin/reads_{umi}.fa", ".amb", ".ann", ".bwt", ".pac", ".sa"),
        umip = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/barcodes_{umi}.fa",
        ref = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/reads_{umi}.fa",
    output:
        OUTPUT_DIR + "/umi/{barcode}/{c}/bin/{umi}_map.sai",
    params:
        n = 3,
    log:
        OUTPUT_DIR + "/logs/umi/{barcode}/{c}/bin/aln_{umi}.log"
    benchmark:
        OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/bin/aln_{umi}.txt"

use rule bwa_samse as samse_umi with:
    input:
        umip = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/barcodes_{umi}.fa",
        ref = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/reads_{umi}.fa",
        sai = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/{umi}_map.sai",
    output:
        OUTPUT_DIR + "/umi/{barcode}/{c}/bin/{umi}_map.sam",
    params:
        F = 20,
    log: 
        OUTPUT_DIR + "/logs/umi/{barcode}/{c}/bin/samse_{umi}.log"
    benchmark: 
        OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/bin/samse_{umi}.txt"

rule umi_binning:
    input:
        umi1 = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/umi1_map.sam",
        umi2 = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/umi2_map.sam",
    output:
        bin_map = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/umi_bin_map.txt",
        stats = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/umi_stats.txt",
    conda: "../envs/umi.yaml"
    params:
        u = config["umi"]["u"],
        U = config["umi"]["U"],
        O = config["umi"]["O"],
        N = config["umi"]["N"],
        S = config["umi"]["S"],
    log: OUTPUT_DIR + "/logs/umi/{barcode}/{c}/bin/umi_binning.log"
    benchmark: OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/bin/umi_binning.txt"
    shell:
        """
        awk \
        -v UME_MATCH_ERROR="{params.u}" \
        -v UME_MATCH_ERROR_SD="{params.U}" \
        -v RO_FRAC="{params.O}" \
        -v MAX_BIN_SIZE="{params.N}"  \
        -v BIN_CLUSTER_RATIO="{params.S}" \
        '
        NR==1 {{
          print "[" strftime("%T") "] ### Read-UMI match filtering ###" > "/dev/stderr";
          print "[" strftime("%T") "] Reading UMI1 match file..." > "/dev/stderr";
        }}
        # Read UMI match file
        NR==FNR {{
          # Extract data from optional fields
          for (i=12; i <= NF; i++){{
            # Find NM field and remove prefix (primary hit err)
            if($i ~ /^NM:i:/){{sub("NM:i:", "", $i); perr = $i}};
            # Find secondary hit field, remove prefix and split hits
            if($i ~ /^XA:Z:/){{sub("XA:Z:", "", $i); split($i, shits, ";")}};
          }}
          # Add primary mapping to hit list
          err1[$1][$3]=perr;
          # Add secondary mapping to hit list
          #Iterate over each hit
          for (i in shits){{
            # Split hit in subdata (read, pos, cigar, err)  
            split(shits[i], tmp, ",");
            # Add hit if non-empty, not seen before and not target reverse strand
            if (tmp[1] != "" && !(tmp[1] in err1[$1]) && tmp[2] ~ "+"){{
              err1[$1][tmp[1]] = tmp[4];
            }}
          }}
          next;
        }}
        FNR==1 {{
         print "[" strftime("%T") "] Reading UMI2 match file..." > "/dev/stderr";
        }}
        # Read UMI match file
        {{
          # Extract data from optional fields
          for (i=12; i <= NF; i++){{
            # Find NM field and remove prefix (primary hit err)
            if($i ~ /^NM:i:/){{sub("NM:i:", "", $i); perr = $i}};
            # Find secondary hit field and remove prefix
            if($i ~ /^XA:Z:/){{sub("XA:Z:", "", $i); split($i, shits, ";")}};
          }}
          # Add primary mapping to hit list
          err2[$1][$3]=perr;
          # Add secondary mapping to hit list
          # Split list of hits 
          #Iterate over each hit
          for (i in shits){{
            # Split hit in subdata (read, pos, cigar, err)
            split(shits[i], tmp, ",");
            # Add hit if non-empty, not seen before and not target reverse strand
            if (tmp[1] != "" && !(tmp[1] in err2[$1]) && tmp[2] ~ "+"){{
              err2[$1][tmp[1]] = tmp[4];
            }}
          }}
        }} END {{
          print "[" strftime("%T") "] UMI match filtering..." > "/dev/stderr"; 
          # Filter reads based on UMI match error
          for (umi in err1){{    
            for (read in err1[umi]){{
              # Define vars
              e1 = err1[umi][read];
              e2 = err2[umi][read];
              # Filter reads not matching both UMIs
              if (e1 != "" && e2 != ""){{
                # Filter based on mapping error 
                if (e1 + e2 <= 6 && e1 <= 3 && e2 <= 3){{
                  # Add read to bin list or replace bin assignment if error is lower
                  if (!(read in match_err)){{
                    match_umi[read] = umi;
                    match_err[read] = e1 + e2;
                  }} else if (match_err[read] > e1 + e2 ){{
                    match_umi[read] = umi;
                    match_err[read] = e1 + e2;
                  }} 
                }}
              }}
            }}
          }}
          print "[" strftime("%T") "] Read orientation filtering..." > "/dev/stderr";
          # Count +/- strand reads
          for (s in match_umi){{
            UM=match_umi[s]
            sub("_rc", "", UM)
            # Read orientation stats
            ROC=match(match_umi[s], /_rc/)
            if (ROC != 0){{
              umi_ro_plus[UM]++
              roc[s]="+"
            }} else {{
              umi_ro_neg[UM]++
              roc[s]="-"
            }}
            # Count reads per UMI bin
            umi_n_raw[UM]++;
          }}
          
          # Calculate read orientation fraction
          for (u in umi_ro_plus){{
            # Check read orientation fraction
            if (umi_ro_plus[u] > 1 && umi_ro_neg[u] > 1){{
              if (umi_ro_plus[u]/(umi_ro_neg[u]+umi_ro_plus[u]) < RO_FRAC ){{
                rof_check[u]="rof_subset"
                rof_sub_neg_n[u] = umi_ro_plus[u]*(1/RO_FRAC-1)
                rof_sub_pos_n[u] = rof_sub_neg_n[u]
              }} else if (umi_ro_neg[u]/(umi_ro_neg[u]+umi_ro_plus[u]) < RO_FRAC ){{
                rof_check[u]="rof_subset"
                rof_sub_neg_n[u]=umi_ro_neg[u]*(1/RO_FRAC-1)
                rof_sub_pos_n[u]=rof_sub_neg_n[u]
              }} else {{
                rof_check[u]="rof_ok"
                rof_sub_neg_n[u]=MAX_BIN_SIZE
                rof_sub_pos_n[u]=MAX_BIN_SIZE
              }}
            }} else {{
              rof_check[u]="rof_fail"
            }}
          }}
          
          # Subset reads
          for (s in match_umi){{
            UMI_NAME=match_umi[s]
            sub("_rc", "", UMI_NAME)
            if(roc[s] == "+"){{
              if(rof_sub_pos_n[UMI_NAME]-- > 0){{
                ror_filt[s]=UMI_NAME
              }}
            }} else if (roc[s] == "-"){{
              if(rof_sub_neg_n[UMI_NAME]-- > 0){{
                ror_filt[s]=UMI_NAME
              }}
            }}
          }}
          print "[" strftime("%T") "] UMI match error filtering..." > "/dev/stderr";
          # Calculate UME stats
          for (s in ror_filt){{
            UM=ror_filt[s]
            # Count matching reads
            umi_n[UM]++;
            # UMI match error stats
            umi_me_sum[UM] += match_err[s]
            umi_me_sq[UM] += (match_err[s])^2
          }}
          # Check UMI match error
          for (u in umi_n){{
            UME_MEAN[u] = umi_me_sum[u]/umi_n[u]
            UME_SD[u] = sqrt((umi_me_sq[u]-umi_me_sum[u]^2/umi_n[u])/umi_n[u])
            if (UME_MEAN[u] > UME_MATCH_ERROR || UME_SD[u] > UME_MATCH_ERROR_SD){{
              ume_check[u] = "ume_fail"
            }} else {{
              ume_check[u] = "ume_ok"
            }}
          }}
          print "[" strftime("%T") "] UMI bin/cluster size ratio filtering..." > "/dev/stderr";
          for (u in umi_n){{
            CLUSTER_SIZE=u
            sub(".*;", "", CLUSTER_SIZE)
            bcr[u]=umi_n_raw[u]/CLUSTER_SIZE
            if (bcr[u] > BIN_CLUSTER_RATIO){{
              bcr_check[u] = "bcr_fail"
            }} else {{
              bcr_check[u] = "bcr_ok"
            }}
          }}
          # Print filtering stats
          print "umi_name", "read_n_raw", "read_n_filt", "read_n_plus", "read_n_neg", \
            "read_max_plus", "read_max_neg", "read_orientation_ratio", "ror_filter", \
            "umi_match_error_mean", "umi_match_error_sd", "ume_filter", "bin_cluster_ratio", \
            "bcr_filter" > "{output.stats}"
          for (u in umi_n){{
            print u, umi_n_raw[u], umi_n[u], umi_ro_plus[u], umi_ro_neg[u], \
              rof_sub_pos_n[u] + umi_ro_plus[u], rof_sub_neg_n[u] + umi_ro_neg[u], rof_check[u], \
              UME_MEAN[u], UME_SD[u], ume_check[u], bcr[u], bcr_check[u]\
              > "{output.stats}"
          }}
        
          print "[" strftime("%T") "] Print UMI matches..." > "/dev/stderr"; 
          for (s in ror_filt){{
            UMI_NAME=ror_filt[s]
            if( \
                ume_check[UMI_NAME] == "ume_ok" && \
                rof_check[UMI_NAME] == "rof_ok" && \
                bcr_check[UMI_NAME] == "bcr_ok" \
            ){{print UMI_NAME, s, match_err[s]}}
          }}
          # Print to terminal
          print "[" strftime("%T") "] Done." > "/dev/stderr"; 
        }}
        ' {input.umi1} {input.umi2} > {output.bin_map} 2> {log}
        """
 
# split reads by umi bins
checkpoint bin_info:
    input: rules.umi_binning.output.bin_map
    output: directory(OUTPUT_DIR + "/umi/{barcode}/{c}/bin/binned")
    log: OUTPUT_DIR + "/logs/kmerBin/{barcode}/{c}/bin/bin_info.log"
    benchmark: OUTPUT_DIR + "/benchmarks/kmerBin/{barcode}/{c}/bin/bin_info.txt"
    run:
        import pandas as pd
        df = pd.read_csv(input[0], sep=" ", header=None, usecols=[0,1], names=["umi","read"])
        df.umi = [x.split(";")[0] for x in df.umi]
        os.makedirs(output[0])
        for umi in set(df.umi):
            df.loc[df.umi == umi, "read"].to_csv(output[0] + "/" + str(umi) + ".txt", sep="\t", header=False, index=False)
        
use rule split_by_cluster as split_by_umi_bin with:
    input: 
        clusters = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/binned/{umi_id}.txt",
        fastq = rules.qfilter_umi.output,
    output:
        OUTPUT_DIR + "/umi/{barcode}/{c}/bin/binned/{umi_id}.fastq"
    log:
        OUTPUT_DIR + "/logs/kmerBin/{barcode}/{c}/bin/split_by_{umi_id}.log"
    benchmark:
        OUTPUT_DIR + "/benchmarks/kmerBi/{barcode}/{c}/bin/split_by_{umi_id}.txt"

# find the seed read
rule fq2fa_umi:
    input: rules.split_by_umi_bin.output
    output: OUTPUT_DIR + "/umi/{barcode}/{c}/bin/binned/{umi_id}.fna"
    conda: "../envs/seqkit.yaml"
    log: OUTPUT_DIR + "/logs/kmerBin/{barcode}/{c}/bin/fq2fa_{umi_id}.log"
    benchmark: OUTPUT_DIR + "/benchmarks/kmerBin/{barcode}/{c}/bin/fq2fa_{umi_id}.txt"
    shell: "seqkit fq2fa {input} -o {output} 2> {log}"

rule get_centroids_umifa:
    input: rules.fq2fa_umi.output
    output: OUTPUT_DIR + "/umi/{barcode}/{c}/bin/binned/{umi_id}_centroid.fna",
    conda: "../envs/vsearch.yaml"
    log: OUTPUT_DIR + "/logs/kmerBin/{barcode}/{c}/bin/get_centroids_{umi_id}.log"
    benchmark: OUTPUT_DIR + "/benchmarks/kmerBin/{barcode}/{c}/bin/get_centroids_{umi_id}.txt"
    threads: config["threads"]["normal"]
    shell:
        """
        vsearch --cluster_fast {input} --clusterout_sort -id 0.75 --clusterout_id --sizeout \
        --centroids {output} --qmask none --threads {threads} --strand both > {log} 2>&1
        """

rule take_seedfa:
    input: rules.get_centroids_umifa.output
    output: OUTPUT_DIR + "/umi/{barcode}/{c}/bin/polish/{umi_id}/draft/raw.fna"
    conda: "../envs/seqkit.yaml"
    log: OUTPUT_DIR + "/logs/kmerBin/{barcode}/{c}/bin/polish/{umi_id}/take_seedfa.log"
    benchmark: OUTPUT_DIR + "/benchmarks/kmerBin/{barcode}/{c}/bin/polish/{umi_id}/take_seedfa.txt"
    shell: "seqkit head -n 1 {input} 2> {log} | seqkit replace -p '^(.+)$' -r 'seed' -o {output} 2>> {log}"  

# align seed with raw reads
# reused in racon iterations
use rule minimap2polish as minimap2polish_umi with:
    input: 
        ref = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/polish/{umi_id}/draft/{assembly}.fna",
        fastq = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/binned/{umi_id}.fastq",
    output: 
        OUTPUT_DIR + "/umi/{barcode}/{c}/bin/polish/{umi_id}/draft/{assembly}.paf",
    message: 
        "Polish umi [id={wildcards.umi_id}]: alignments against {wildcards.assembly} assembly [{wildcards.barcode}]"
    log: 
        OUTPUT_DIR + "/logs/umi/{barcode}/{c}/bin/polish/{umi_id}/minimap2polish/{assembly}.log"
    benchmark: 
        OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/bin/polish/{umi_id}/minimap2polish/{assembly}.txt"

def get_racon_input_umi(wildcards):
    # adjust input based on racon iteritions
    if int(wildcards.iter) == 1:
        prefix = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/polish/{umi_id}/draft/raw"
        return(prefix + ".paf", prefix + ".fna")
    else:
        prefix = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/polish/{umi_id}/draft/racon_{iter}".format(barcode=wildcards.barcode,
         umi_id=wildcards.umi_id, iter=str(int(wildcards.iter) - 1))
        return(prefix + ".paf", prefix + ".fna")

use rule racon as racon_umi with:
    input:
        OUTPUT_DIR + "/umi/{barcode}/{c}/bin/binned/{umi_id}.fastq",
        get_racon_input_umi,
    output: 
        OUTPUT_DIR + "/umi/{barcode}/{c}/bin/polish/{umi_id}/draft/racon_{iter}.fna"
    message: 
        "Polish umi draft [id={wildcards.umi_id}] with racon, round={wildcards.iter} [{wildcards.barcode}]"
    log: 
        OUTPUT_DIR +"/logs/umi/{barcode}/{c}/bin/polish/{umi_id}/racon/round{iter}.log"
    benchmark: 
        OUTPUT_DIR +"/benchmarks/umi/{barcode}/{c}/bin/polish/{umi_id}/racon/round{iter}.txt"

use rule medaka_consensus as medaka_consensus_umi with:
    input:
        fna = expand(OUTPUT_DIR + "/umi/{{barcode}}/{{c}}/bin/polish/{{umi_id}}/draft/racon_{iter}.fna", 
        iter = config["racon"]["iter"]),
        fastq = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/binned/{umi_id}.fastq",
    output: 
        fasta = OUTPUT_DIR + "/umi/{barcode}/{c}/bin/polish/{umi_id}/medaka/consensus.fasta",
        _dir = directory(OUTPUT_DIR + "/umi/{barcode}/{c}/bin/polish/{umi_id}/medaka"),
    message: 
        "Generate umi consensus [id={wildcards.umi_id}] with medaka [{wildcards.barcode}]"
    log: 
        OUTPUT_DIR + "/logs/umi/{barcode}/{c}/bin/polish/{umi_id}/medaka.log"
    benchmark: 
        OUTPUT_DIR + "/benchmarks/umi/{barcode}/{c}/bin/polish/{umi_id}/medaka.txt"

def get_umiCon(wildcards, kmerbin = True):
    check_val("kmerbin", kmerbin, bool)
    barcodes = get_demultiplexed(wildcards)

    fnas = []
    for i in barcodes:
        if kmerbin == True:
            cs = glob_wildcards(checkpoints.cluster_info_umi.get(barcode=i).output[0] + "/{c}.txt").c
        else:
            cs = ["all"]
        for j in cs:
            uids = glob_wildcards(checkpoints.bin_info.get(barcode=i, c=j).output[0] + "/{uid}.txt").uid
            for k in uids:
                fnas.append(OUTPUT_DIR + "/umi/{barcode}/{c}/bin/polish/{uid}/medaka/consensus.fasta".format(barcode=i, uid=k))
    return fnas

rule collect_umiCon:
    input: lambda wc: get_umiCon(wc, kmerbin = config["kmerbin"]),
    output: OUTPUT_DIR + "/umi/umiCon_full.fna"
    run: 
        with open(output[0], "w") as out:
            for i in input:
                barcode_i, uid_i = [ i.split("/")[index] for index in [-5, -2] ]
                with open(i, "r") as inp:
                    for line in inp:
                        if line.startswith(">"):
                            line = ">" + barcode_i + "_" + uid_i + "\n"
                        out.write(line)

# trim primers 
use rule trim_primers as trim_umiCon with:
    input: 
        rules.collect_umiCon.output
    output: 
        OUTPUT_DIR + "/umiCon.fna"
    log: 
        OUTPUT_DIR + "/logs/umi/trim_umiCon.log"
    benchmark: 
        OUTPUT_DIR + "/benchmarks/umi/trim_umiCon.txt"
    