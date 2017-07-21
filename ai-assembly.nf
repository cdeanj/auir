#!/usr/bin/env nextflow

/*
vim: syntax=groovy
-*- mode: groovy;-*-
================================================================================
=                     A I | A S S E M B L Y | P I P E L I N E                  =
================================================================================
@Author
Christopher Dean <cdean11@colostate.edu>
--------------------------------------------------------------------------------
 @Homepage
 https://github.com/cdeanj/ai-assembly-pipeline
--------------------------------------------------------------------------------
 @Documentation
 https://github.com/cdeanj/ai-assembly-pipeline/blob/master/README.md
--------------------------------------------------------------------------------
@Licence
 https://github.com/cdeanj/ai-ssembly-pipeline/blob/master/LICENSE
--------------------------------------------------------------------------------
 Processes overview
 - Run AI pipeline
================================================================================
=                           C O N F I G U R A T I O N                          =
================================================================================
*/

threads = params.threads
adapters = file(params.adapters)
leading = params.leading
trailing = params.trailing
slidingwindow = params.slidingwindow
minlen = params.minlen

Channel
    .fromFilePairs( params.reads, flat: true )
    .ifEmpty { exit 1, "Read pair files could not be found: ${params.reads}" }
    .into { read_pairs }

process Trimmomatic {
    tag { dataset_id }

    publishDir "${params.output}/Trimmomatic", mode: 'copy',
        saveAs: { filename ->
            if(filename.indexOf("P.fastq") > 0) "Paired/$filename"
            else if(filename.indexOf("U.fastq") > 0) "Unpaired/$filename"
            else if(filename.indexOf(".log") > 0) "Log/$filename"
            else {}
        }
	
    input:
        set dataset_id, file(forward), file(reverse) from read_pairs

    output:
        set dataset_id, file("${dataset_id}.1P.fastq"), file("${dataset_id}.2P.fastq") into (paired_fastq)
        set dataset_id, file("${dataset_id}.1U.fastq"), file("${dataset_id}.2U.fastq") into (unpaired_fastq)
        set dataset_id, file("${dataset_id}.trimmomatic.stats.log") into (trimmomatic_logs)

    """
    java -jar ${TRIMMOMATIC}/trimmomatic-0.36.jar \
      PE \
      -threads ${threads} \
      $forward $reverse -baseout ${dataset_id} \
      ILLUMINACLIP:${adapters}:2:30:10:3:TRUE \
      LEADING:${leading} \
      TRAILING:${trailing} \
      SLIDINGWINDOW:${slidingwindow} \
      MINLEN:${minlen} \
      2> ${dataset_id}.trimmomatic.stats.log

    mv ${dataset_id}_1P ${dataset_id}.1P.fastq
    mv ${dataset_id}_2P ${dataset_id}.2P.fastq
    mv ${dataset_id}_1U ${dataset_id}.1U.fastq
    mv ${dataset_id}_2U ${dataset_id}.2U.fastq
    """
}

process SPAdes {
    tag { dataset_id }

    publishDir "${params.output}/SPAdes", mode: "copy"

    input:
        set dataset_id, file(forward), file(reverse) from paired_fastq

    output:
        set dataset_id, file("${dataset_id}.contigs.fa") into (spades_contigs)

    """
    spades.py \
      -t ${threads} \
      --only-assembler \
      --cov-cutoff auto \
      -1 ${forward} \
      -2 ${reverse} \
      -o output

    mv output/contigs.fasta .
    mv contigs.fasta ${dataset_id}.contigs.fa
    """
}

process Blastn {
    tag { dataset_id }

    publishDir "${params.output}/Blastn", mode: 'copy'

    input:
        set dataset_id, file(contigs) from spades_contigs

    output:
        set dataset_id, file("${dataset_id}.contigs.annotated.fa") into (annotated_spades_contigs)

    """
    blastn -db InfluenzaDB -query ${contigs} -max_hsps 1 -max_target_seqs 1 -outfmt "10 stitle" -num_threads ${threads} > ${dataset_id}.contig.description.tmp
    cat ${dataset_id}.contig.description.tmp | sed -e '/Influenza/s/^/>/' > ${dataset_id}.contig.description.txt
    awk '/^>/ { getline <"${dataset_id}.contig.description.txt" } 1 ' ${contigs} > ${dataset_id}.contigs.annotated.fa
    """
}

annotated_assemblies = Channel.empty()
    .mix(annotated_spades_contigs)
    .flatten()
    .toList()

process QUAST {
    publishDir "${params.output}/QUAST", mode: 'copy'

    input:
        file(annotated_contigs) from annotated_assemblies

    output:
        set file("report.tsv") into (quast_logs)

    """
    quast.py \
      ${annotated_contigs} \
      --no-plots \
      --no-html \
      --no-icarus \
      --no-snps \
      --no-sv \
      --est-ref-size 13600 \
      -t ${threads} \
      -o output

    mv output/report.tsv .
    """
}

multiQCReports = Channel.empty()
    .mix(
        trimmomatic_logs,
        quast_logs
    )
    .flatten().toList()

process MultiQC {
    publishDir "${params.output}/MultiQC", mode: 'copy'

    input:
        file('*') from multiQCReports

    output:
        set file("*multiqc_report.html") into multiQCReport

    """
    multiqc -f -v .
    """
}
