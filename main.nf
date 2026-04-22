#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

process convert_image_series {
    publishDir params.output, overwrite: true, mode: "copy"
    container "${params.container}"

    input:
        path "inputs"
        path script

    output:
        path "*.ome.tif"
        path "*.log.txt"
        path "*.metadata.json"

    script:
        """#!/bin/bash
set -e

for IMG_FILE in inputs/*.${params.image_format}; do
    echo "\$(date) Converting \$IMG_FILE"
    LOG_TXT="\${IMG_FILE#inputs/}.log.txt"
    QuPath script \
        --args "\$IMG_FILE" \
        --args "\$PWD" \
        --args "${params.compression}" \
        --args "${params.image_format}" \
        "${script}" | tee "\$LOG_TXT"
done
echo "\$(date) Done"
        """
}


process convert_image {
    publishDir params.output, overwrite: true, mode: "copy"
    container "${params.container}"

    input:
        path "inputs"
        path script

    output:
        path "*.ome.tif"
        path "*.log.txt"

    script:
        """#!/bin/bash
set -eu

for IMG_FILE in inputs/*.${params.image_format}; do
    OUTPUT_PREFIX=\${IMG_FILE##*/}
    OUTPUT_PREFIX=\${OUTPUT_PREFIX%.${params.image_format}}
    echo "\$(date) Converting \$IMG_FILE (Output Prefix: \$OUTPUT_PREFIX)"
    LOG_TXT="\${OUTPUT_PREFIX}.log.txt"
    QuPath convert-ome \
             "\$IMG_FILE" \
             "\$OUTPUT_PREFIX" \
             --pyramid-scale=${params.pyramid_scale} \
             --tile-size=${params.tile_size} \
             --compression=${params.compression} \
             --parallelize | tee "\$LOG_TXT"

done
echo "\$(date) Done"
        """
}

workflow {
    script = file("$projectDir/img2tiff_headless.groovy", checkIfExists: true)
    input_folder = file(params.input_folder, type: 'dir', checkIfExists: true)
    if ( params.image_format in ['vsi', 'scn', 'dcm', 'dicom', 'nd2', 'lif', 'czi'] ){
        convert_image_series(input_folder, script)
    } else {
        convert_image(input_folder, script)
    }
}