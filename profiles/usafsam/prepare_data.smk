ruleorder: prepare_sequences > parse

# Assumes that metadata XLS is the XLS metadata file downloaded from GISAID for
# the same samples that appear in the raw sequences FASTA below.
#
# 1. Convert metadata from XLS to CSV for better downstream parsing.
# 2. Select only the metadata fields that we need.
# 3. Rename GISAID fields to Nextstrain standard field names.
# 4. Split the "location" field into four separate geographic fields with standard Nextstrain field names.
# 5. Remove whitespace in strain names to make names consistent with the sequence records as processed below.
# 6. Sort records in descending order by strain name and accession such that the most recent accession for each strain appears first.
# 7. Select the first record for each unique strain name in the metadata, keeping the most recent accession.
rule prepare_metadata:
    input:
        metadata="data/{lineage}/metadata.xlsx",
    output:
        metadata="data/{lineage}/metadata.tsv",
    params:
        blank_fields=",".join(config["blank_metadata_fields"]),
    conda: "../../workflow/envs/nextstrain.yaml"
    shell:
        """
        csvtk xlsx2csv {input.metadata} \
            | csvtk replace -f {params.blank_fields} -p '^$' -r 'BLANK' \
            | csvtk replace -f strain -p " " -r "" \
            | csvtk sort -k strain \
            | csvtk uniq -T -f strain > {output.metadata}
        """

# Assumes that "raw sequences" FASTA is downloaded from GISAID with only the
# "Isolate_name" field selected such that each record looks like:
# ">strain name|accession".
#
# 1. Remove spaces from strain names.
# 2. Add unique id to duplicate strain name and accession pairs.
# 3. Sort sequences in descending order by strain and accession (latest accession comes first).
# 4. Replace "|" character with space, changing record name to strain name only.
# 5. Keep the first sequence for a given strain name, keeping the sequence for the most recent accession.
rule prepare_sequences:
    input:
        sequences="data/{lineage}/raw_sequences_{segment}.fasta",
    output:
        sequences="data/{lineage}/{segment}.fasta",
    conda: "../../workflow/envs/nextstrain.yaml"
    shell:
        """
        seqkit replace -p " " -r "" {input.sequences} \
            | seqkit rename \
            | seqkit sort -n -r \
            | seqkit replace -p "\|" -r " " \
            | seqkit rmdup > {output.sequences}
        """
