#!/bin/bash

source /application/libexec/functions.sh

export LM_LICENSE_FILE=1700@idl.terradue.com
#export MODTRAN_BIN=/opt/MODTRAN-5.4.0
export STEMP_BIN=/data/code/code_S2
export IDL_BIN=/usr/local/bin
export PROCESSING_HOME=${TMPDIR}/PROCESSING

function main() {

  local ref=$1
  local identifier=$2
  local mission=$3
  local date=$4
  local station=$5
  local region=$6
  local volcano=$7
  local geom=$8
  # UTM_ZONE variable comes from the dcs-stemp-l8 application. In this case we get the UTM_ZONE from the volcanoes DB.
  local utm_zone=$9
  UTM_ZONE=${utm_zone%%*( )}

  local v_lon=$( echo "${geom}" | sed -n 's#POINT(\(.*\)\s.*)#\1#p')
  local v_lat=$( echo "${geom}" | sed -n 's#POINT(.*\s\(.*\))#\1#p')

  volcano=$( echo ${volcano} | tr ' ' _ )

  ciop-log "INFO" "**** STEMP node ****"
  ciop-log "INFO" "------------------------------------------------------------"
  ciop-log "INFO" "Mission: ${mission}"
  ciop-log "INFO" "Input product reference: ${ref}"
  ciop-log "INFO" "Date and time: ${date}"
  ciop-log "INFO" "Reference atmospheric station: ${station}, ${region}"
  ciop-log "INFO" "Volcano name: ${volcano}"
  ciop-log "INFO" "Geometry in WKT format: ${geom}"
  ciop-log "INFO" "UTM Zone: ${UTM_ZONE}"
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Preparing the STEMP environment"
  export PROCESSING_HOME=${TMPDIR}/PROCESSING
  mkdir -p ${PROCESSING_HOME}
#  ln -sf /opt/MODTRAN-5.4.0/Mod5.4.0tag/DATA ${PROCESSING_HOME}/DATA

#  ciop-log "INFO" "Getting atmospheric profile"
#  profile=$( getRas "${date}" "${station}" "${region}" "${PROCESSING_HOME}") || return ${ERR_GET_RAS}
#  ciop-log "INFO" "Atmospheric profile downloaded"
#  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Getting Digital Elevation Model"
  dem=$( getDem "${geom}" "${PROCESSING_HOME}" ) || return ${ERR_GET_DEM}
  ciop-log "INFO" "Digital Elevation Model downloaded"
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Converting Digital Elevation Model to GeoTIFF"

  mv ${dem}.rsc ${PROCESSING_HOME}/dem.rsc
  mv ${dem} ${PROCESSING_HOME}/dem

  dem_geotiff=$( convertDemToGeoTIFF "${PROCESSING_HOME}/dem.rsc" "${PROCESSING_HOME}/dem" "${PROCESSING_HOME}" ) || return ${ERR_CONV_DEM}
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Croppig Digital Elevation Model"

  # Extent in degree
  local extent=0.3
  cropped_dem=$( cropDem "${dem_geotiff}" "${PROCESSING_HOME}" "${v_lon}" "${v_lat}" "${extent}" ) || return ${ERR_CROP_DEM}
  ciop-log "INFO" "------------------------------------------------------------"
  
  if [ ${LOCAL_DATA} == "true" ]; then
    ciop-log "INFO" "Getting local input product"
    product=$( ciop-copy -f -U -O ${PROCESSING_HOME} /data/SCIHUB/${identifier}.zip)
  else  
    ciop-log "INFO" "Getting remote input product"
    product=$( getData "${ref}" "${PROCESSING_HOME}" ) || return ${ERR_GET_DATA}
  fi
  
  ciop-log "INFO" "Input product downloaded"
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Uncompressing product"

  unzip -qq -o -j ${product} */GRANULE/*/IMG_DATA/*B04.jp2 */GRANULE/*/IMG_DATA/*B8A.jp2 */GRANULE/*/IMG_DATA/*B12.jp2 -d ${PROCESSING_HOME} 
  res=$?
  [ ${res} -ne 0 ] && return ${$ERR_UNCOMP}
  ciop-log "INFO" "Product uncompressed"
  ciop-log "INFO" "------------------------------------------------------------"

  for granule_band in $( ls ${PROCESSING_HOME}/*.jp2 ); do
    granule_band_identifier=$( basename ${granule_band})
    granule_band_identifier=${granule_band_identifier%.jp2}

    gdal_translate ${granule_band} ${PROCESSING_HOME}/${granule_band_identifier}.tif

    mv ${PROCESSING_HOME}/${granule_band_identifier}.tif ${PROCESSING_HOME}/${granule_band_identifier}.tif.tmp

    # Convert S2 product to proper UTM zone - TODO: to be verified
    gdalwarp -t_srs "+proj=utm +zone=${UTM_ZONE} +${n_s} +datum=WGS84"  ${PROCESSING_HOME}/${granule_band_identifier}.tif.tmp ${PROCESSING_HOME}/${granule_band_identifier}.tif
  done

  for granule_band_04 in $( ls ${PROCESSING_HOME}/*B04.tif ); do
    # Converting B04 from 10m to 20m resolution
    mv ${granule_band_04} ${granule_band_04}.tmp
    gdalwarp -tr 20 20 ${granule_band_04}.tmp ${granule_band_04} 
  done

#  ciop-log "INFO" "Getting the emissivity file and spectral response functions"
#  ciop-log "INFO" "${EMISSIVITY_AUX_PATH}/${volcano}.tif"
#  cp ${EMISSIVITY_AUX_PATH}/default.tif ${PROCESSING_HOME}/${volcano}.tif
#  cp ${EMISSIVITY_AUX_PATH}/*.txt ${PROCESSING_HOME}

#  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Checking the UTM Zone"
  ciop-log "INFO" "UTM Zone: ${UTM_ZONE}"
  
  # If the volcano is located in southern hemisphere
  if [ $( echo "${v_lat} < 0" | bc ) -eq 1 ]; then
    n_s="south"
  else
    n_s="north"
  fi
  
#  ciop-log "INFO" "Resampling product to 1km"
  ciop-log "INFO" "Converting product to UTM zone ${UTM_ZONE} ${n_s}"
  gdalwarp -t_srs "+proj=utm +zone=${UTM_ZONE} +${n_s} +datum=WGS84"  ${PROCESSING_HOME}/${identifier:0:31}.tif ${PROCESSING_HOME}/${identifier:0:31}_UTM.tif
  
  # temp TODO
  ls ${PROCESSING_HOME}
  
  ciop-log "INFO" "Converting product from current resolution to 1km resolution"
  gdalwarp -tr 1000 -1000 ${PROCESSING_HOME}/${identifier:0:31}_UTM.tif ${PROCESSING_HOME}/${identifier:0:31}_UTM_${volcano}_1km.TIF
  
  ciop-log "INFO" "Converting DEM to UTM zone ${UTM_ZONE} ${n_s}"
  gdalwarp -t_srs "+proj=utm +zone=${UTM_ZONE} +${n_s} +datum=WGS84" ${cropped_dem} ${PROCESSING_HOME}/dem_UTM.TIF 1>&2

  ciop-log "INFO" "Setting DEM resolution to 1km"
  gdalwarp -tr 1000 -1000 ${PROCESSING_HOME}/dem_UTM.TIF ${PROCESSING_HOME}/dem_UTM_1km.TIF 1>&2
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Preparing file_input.cfg"
  echo "${identifier:0:31}_UTM_${volcano}_1km.TIF" >> ${PROCESSING_HOME}/file_input.cfg

  basename ${profile} >> ${PROCESSING_HOME}/file_input.cfg
  echo "dem_UTM_1km.TIF" >> ${PROCESSING_HOME}/file_input.cfg
  echo "${volcano}.tif" >> ${PROCESSING_HOME}/file_input.cfg

  ciop-log "INFO" "file_input.cfg content:"
  cat ${PROCESSING_HOME}/file_input.cfg 1>&2
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "PROCESSING_HOME content:"
  ls -l ${PROCESSING_HOME} 1>&2

  ciop-log "INFO" "STEMP environment ready"
  ciop-log "INFO" "------------------------------------------------------------"

  if [ "${DEBUG}" = "true" ]; then
    ciop-publish -m ${PROCESSING_HOME}/*.TIF || return $?
    ciop-publish -m ${PROCESSING_HOME}/*.tif || return $?
    ciop-publish -m ${PROCESSING_HOME}/*txt || return $?
    ciop-publish -m ${PROCESSING_HOME}/dem* || return $?
  fi

  ciop-log "INFO" "Starting STEMP core"
  ${IDL_BIN}/idl -rt=${STEMP_BIN}/STEMP_S3.sav -IDL_DEVICE Z
  ${IDL_BIN}/idl -rt=${STEMP_BINclass}/classificazione.sav -IDL_DEVICE Z

  ciop-log "INFO" "STEMP core finished"
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Generating quicklooks"

  cd ${PROCESSING_HOME}
  string_inp=$(head -n 1 file_input.cfg)
  leng=${#string_inp}
  generateQuicklook ${PROCESSING_HOME}/${string_inp:0:leng-4}_TEMPclass.tif ${PROCESSING_HOME}

  ciop-log "INFO" "Quicklooks generated:"
  ls -l ${PROCESSING_HOME}/*TEMP*.png* 1>&2
  ciop-log "INFO" "------------------------------------------------------------"
  
  METAFILE=${PROCESSING_HOME}/${string_inp:0:leng-4}_TEMP.tif.properties
  DATETIME=${string_inp:16:4}-${string_inp:20:2}-${string_inp:22:2}T${string_inp:25:2}:${string_inp:27:2}:${string_inp:29:2}

  echo "#Predefined Metadata" >> ${METAFILE}
  echo "title=STEMP - Surface Temperature Map" >> ${METAFILE}
  #echo "date=${identifier:16:30}" >> ${METAFILE}
  echo "date=${DATETIME}" >> ${METAFILE}
  echo "Volcano=${volcano}"  >> ${METAFILE}
  echo "#Input scene" >> ${METAFILE}
  echo "Satellite=Sentinel3" >> ${METAFILE}
  echo "#STEMP Parameters" >> ${METAFILE}
  echo "Emissivity=Computed with TES algorithm"  >> ${METAFILE}
  echo "Atmospheric\ Profile=$( basename ${profile} )"  >> ${METAFILE}
  echo "DEM\ Spatial\ Resolution=1Km"  >> ${METAFILE}
  echo "Temperature\ Unit=degree" >> ${METAFILE}
  image_url= https://store.terradue.com/api/ingv-stemp/images/paletta.png
  echo "#EOF"  >> ${METAFILE}
  
  ciop-log "INFO" "Staging-out results ..."
  ciop-publish -m ${PROCESSING_HOME}/*TEMP*.tif || return $?
  ciop-publish -m ${PROCESSING_HOME}/*TEMP*.png* || return $?
  ciop-publish -m ${METAFILE} || return $?
  ciop-publish -m ${PROCESSING_HOME}/*hdf || return $?
  [ ${res} -ne 0 ] && return ${ERR_PUBLISH}

  ciop-log "INFO" "Results staged out"
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Cleaning STEMP environment"
  rm -rf ${PROCESSING_HOME}/*
  ciop-log "INFO" "------------------------------------------------------------"
  ciop-log "INFO" "**** STEMP node finished ****"
}

while IFS=',' read ref identifier mission date station region volcano geom utm_zone
do
    main "${ref}" "${identifier}" "${mission}" "${date}" "${station}" "${region}" "${volcano}" "${geom}" "${utm_zone}" || exit $?
done

exit ${SUCCESS}
