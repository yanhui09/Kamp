# primer info
fprimers = config["fprimer"]
rprimers = config["rprimer"]

def revcomp(seq):
    return seq.translate(str.maketrans('ACGTacgtRYMKrymkVBHDvbhd', 'TGCAtgcaYRKMyrkmBVDHbvdh'))[::-1]
# nanopore possibly sequences either strand
def seqs_join(primer1, primer2):
    joined = '-g ' + primer1 + '...' + revcomp(primer2)
    return joined
def linked_pattern(primers1, primers2):
    primers1_values = list(primers1.values())
    primers2_values = list(primers2.values())
    linked = [seqs_join(primer1, primer2) for primer1 in primers1_values for primer2 in primers2_values]
    return ' '.join(linked)
# pattern
f5_pattern1 = linked_pattern(fprimers, rprimers)
f5_pattern2 = linked_pattern(rprimers, fprimers)

rule subsample:
    input: rules.collect_fastq.output
    output:
        p = temp("qc/subsampled/{barcode}_p.fastq"),
        n = temp("qc/subsampled/{barcode}.fastq"),
    conda: "../envs/seqkit.yaml"
    params:
        n = config["seqkit"]["n"],
    log: "logs/qc/subsample/{barcode}.log"
    benchmark: "benchmarks/qc/subsample/{barcode}.txt"
    resources:
        mem = config["mem"]["normal"],
        time = config["runtime"]["simple"],
    shell:
        """
        nlines=$(cat {input} | wc -l)
        nreads=$((nlines / 4))
        p=$(echo "scale=1; {params.n} / $nreads + 0.1" | bc)
        if (( $(echo "$p > 1" | bc -l) )); then
            p=1
        fi
        seqkit sample -p $p -j {threads} {input} -o {output.p} -w0 -s123 2> {log}
        seqkit head -n {params.n} -j {threads} {output.p} -o {output.n} -w0 2>> {log}
        """

def get_raw(subsample = config["subsample"], n = config["seqkit"]["n"]):
    check_val("subsample", subsample, bool)
    check_val("n[seqkit]", n, int)
    if subsample is True:
        return rules.subsample.output.n
    else:
        return rules.collect_fastq.output

# read scrubbing
rule minimap2ava_yacrd:
    input: get_raw()
    output: temp("qc/yacrd/{barcode}.paf")
    conda: "../envs/yacrd.yaml"
    params:
        x = config["minimap2"]["x_ava"],
        g = config["yacrd"]["minimap2"]["g"],
        f = config["yacrd"]["minimap2"]["f"],
    log: "logs/qc/yacrd/{barcode}_ava.log"
    benchmark: "benchmarks/qc/yacrd/{barcode}_ava.txt"
    threads: config["threads"]["large"]
    resources:
        mem = config["mem"]["large"],
        time = config["runtime"]["simple"],
    shell: "minimap2 -x {params.x} -g {params.g} -f {params.f} -t {threads} {input} {input} > {output} 2> {log}"

rule yacrd:
    input: 
        fq = get_raw(),
        ava = rules.minimap2ava_yacrd.output
    output: temp("qc/yacrd/{barcode}.fastq")
    conda: "../envs/yacrd.yaml"
    params:
        c = config["yacrd"]["c"],
        n = config["yacrd"]["n"],
    log: "logs/qc/yacrd/{barcode}_scrubb.log"
    benchmark: "benchmarks/qc/yacrd/{barcode}_scrubb.txt"
    threads: config["threads"]["large"]
    resources:
        mem = config["mem"]["large"],
        time = config["runtime"]["simple"],
    shell: "yacrd -i {input.ava} -o {log} -c {params.c} -n {params.n} -t {threads} scrubb -i {input.fq} -o {output} 2>> {log}"

def get_chimera_free(read_scrubb= config["read_scrubb"]):
    check_val("read_scrubb", read_scrubb, bool)
    if read_scrubb is True:
        return rules.yacrd.output
    else:
        return get_raw()

# trim primers, process two strands differently
rule trim_primers:
    input: get_chimera_free()
    output: 
        trimmed = temp("qc/primers_trimmed/{barcode}F.fastq"),
        untrimmed = temp("qc/primers_untrimmed/{barcode}F.fastq"),
    conda: "../envs/cutadapt.yaml"
    params:
        f = f5_pattern1,
        e = config["cutadapt"]["max_errors"],
        O = config["cutadapt"]["min_overlap"],
        m = 1,
    log: "logs/qc/trim_primersF/{barcode}.log"
    benchmark: "benchmarks/qc/trim_primersF/{barcode}.txt"
    threads: config["threads"]["large"]
    resources:
        mem = config["mem"]["normal"],
        time = config["runtime"]["simple"],
    shell:
        """
        cutadapt \
        -j {threads} \
        -e {params.e} -O {params.O} -m {params.m} \
        {params.f} \
        --untrimmed-output {output.untrimmed} \
        -o {output.trimmed} \
        {input} \
        > {log} 2>&1
        """

use rule trim_primers as trim_primersR with:
    input: 
        rules.trim_primers.output.untrimmed
    output:
        trimmed = temp("qc/primers_trimmed/{barcode}R.fastq"),
        untrimmed = temp("qc/primers_untrimmed/{barcode}.fastq"),
    params:
        f = f5_pattern2,
        e = config["cutadapt"]["max_errors"],
        O = config["cutadapt"]["min_overlap"],
        m = 1,
    log: 
        "logs/qc/trim_primersR/{barcode}.log"
    benchmark: 
        "benchmarks/qc/trim_primersR/{barcode}.txt"

# reverse complement for reverse strand
rule revcomp_fq:
    input: rules.trim_primersR.output.trimmed
    output: temp("qc/primers_trimmed/{barcode}R_revcomp.fastq")
    conda: "../envs/seqkit.yaml"
    log: "logs/qc/revcomp_fq/{barcode}.log"
    benchmark: "benchmarks/qc/revcomp_fq/{barcode}.txt"
    threads: config["threads"]["normal"]
    resources:
        mem = config["mem"]["normal"],
        time = config["runtime"]["simple"],
    shell: "seqkit seq -j {threads} -r -p -t dna {input} > {output} 2> {log}"

# option to trim or not
def trim_check(trim = config["trim"], subsample = config["subsample"], n = config["seqkit"]["n"]):
    check_val("trim", trim, bool)
    out = [rules.trim_primers.output.trimmed, rules.revcomp_fq.output]
    if trim is False:
        out = get_raw(subsample, n)
    return out

rule q_filter:
    input: trim_check()
    output: "qc/qfilt/{barcode}.fastq"
    conda: "../envs/seqkit.yaml"
    params:
        Q = config["seqkit"]["min_qual"],
        m = config["seqkit"]["min_len"],
        M = config["seqkit"]["max_len"],
    log: "logs/qc/q_filter/{barcode}.log"
    benchmark: "benchmarks/qc/q_filter/{barcode}.txt"
    threads: config["threads"]["normal"]
    resources:
        mem = config["mem"]["normal"],
        time = config["runtime"]["simple"],
    shell: "cat {input} | seqkit seq -j {threads} -Q {params.Q} -m {params.m} -M {params.M} -i > {output} 2> {log}"

checkpoint exclude_empty_fqs:
    input: lambda wc: expand("qc/qfilt/{barcode}.fastq", barcode=get_demux_barcodes(wc))
    output: touch(".qc_DONE")

def get_qced_barcodes(wildcards):
    barcodes = get_demux_barcodes(wildcards)
    checkflag = checkpoints.exclude_empty_fqs.get(**wildcards).output[0]
    for i in barcodes:
        if os.stat("qc/qfilt/" + i + ".fastq").st_size == 0:
            barcodes.remove(i)
    return barcodes

localrules: combine_fastq
#  sample pooling to increase sensitivity 
rule combine_fastq:
    input: lambda wc: expand("qc/qfilt/{barcode}.fastq", barcode=get_qced_barcodes(wc))
    output: "qc/qfilt/pooled.fastq"
    shell: "cat {input} > {output}"

def get_filt(wildcards, pool = config["pool"]):
    barcodes = get_qced_barcodes(wildcards) 
    check_val("pool", pool, bool)
    if pool is True:
        barcodes.append("pooled")
    return expand("qc/qfilt/{barcode}.fastq", barcode=barcodes)