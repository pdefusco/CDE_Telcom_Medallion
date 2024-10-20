#!/bin/sh

docker_user=$1
cde_user=$2
max_participants=$3
cdp_data_lake_storage=$4

cde_user_formatted=${cde_user//[-._]/}
d=$(date)
fmt="%-30s %s\n"

echo "##########################################################"
printf "${fmt}" "CDE HOL deployment launched."
printf "${fmt}" "launch time:" "${d}"
printf "${fmt}" "performed by CDP User:" "${cde_user}"
printf "${fmt}" "performed by Docker User:" "${docker_user}"
echo "##########################################################"

echo "CREATE SPARK FILES SHARED RESOURCE"
cde resource delete --name Spark-Files-Shared
cde resource create --type files --name Spark-Files-Shared
cde resource upload --name Spark-Files-Shared \
    --local-path cde_spark_jobs/parameters.conf \
    --local-path cde_spark_jobs/utils.py \
    --local-path cde_spark_jobs/001_Lakehouse_Bronze.py \
    --local-path cde_spark_jobs/002_Lakehouse_Silver.py \
    --local-path cde_spark_jobs/003_Lakehouse_Gold.py \
    --local-path setup/purge.py

echo "CREATE & RUN PURGE TABLES JOB"
cde job create \
  --name purge-tables \
  --application-file purge.py \
  --executor-memory "2g" \
  --executor-cores "2" \
  --arg $max_participants \
  --arg $cdp_data_lake_storage
cde job run \
  --name purge-tables

function loading_icon_job() {
  local loading_animation=( '—' "\\" '|' '/' )

  echo "${1} "

  tput civis
  trap "tput cnorm" EXIT

  while true; do
    job_status=$(cde run list --filter 'job[like]%purge-tables' | jq -r '[last] | .[].status')
    if [[ $job_status == "succeeded" ]]; then
      echo "Setup Job Execution Completed"
      break
    else
      for frame in "${loading_animation[@]}" ; do
        printf "%s\b" "${frame}"
        sleep 1
      done
    fi
  done
  printf " \b\n"
}

loading_icon_job "Purge Tables Job in Progress"

echo "RERUN SETUP JOBS"
echo "RECREATE & RUN MKTHOL SETUP JOB"
cde job create --name mkt-hol-setup-$cde_user --type spark \
  --mount-1-resource mkt-hol-setup-$cde_user --application-file setup.py \
  --runtime-image-resource-name dex-spark-runtime-$cde_user \
  --arg $max_participants --arg $cdp_data_lake_storage \
  --executor-cores 5 --executor-memory "8g"
cde job run --name mkt-hol-setup-$cde_user

function loading_icon_job() {
  local loading_animation=( '—' "\\" '|' '/' )

  echo "${1} "

  tput civis
  trap "tput cnorm" EXIT

  while true; do
    job_status=$(cde run list --filter 'job[like]%mkt-hol-setup-'$cde_user | jq -r '[last] | .[].status')
    if [[ $job_status == "succeeded" ]]; then
      echo "Setup Job Execution Completed"
      break
    else
      for frame in "${loading_animation[@]}" ; do
        printf "%s\b" "${frame}"
        sleep 1
      done
    fi
  done
  printf " \b\n"
}

loading_icon_job "Setup Job in Progress"

echo "RECREATE & RUN BRONZE JOB"
cde job delete \
  --name spark_bronze
cde job create \
  --name spark_bronze \
  --arg user001 \
  --type spark \
  --mount-1-resource Spark-Files-Shared \
  --application-file 001_Lakehouse_Bronze.py \
  --driver-cores 2 \
  --driver-memory "4g" \
  --executor-cores 4 \
  --executor-memory "10g"
cde job run \
  --name spark_bronze

echo "RECREATE MEDALLION PIPELINE JOBS"
cde job delete \
  --name spark_bronze
cde job delete \
  --name spark_silver
cde job delete \
  --name spark_gold
cde job create \
  --name spark_bronze \
  --arg user001 \
  --type spark \
  --mount-1-resource Spark-Files-Shared \
  --application-file 001_Lakehouse_Bronze.py \
  --driver-cores 2 \
  --driver-memory "4g" \
  --executor-cores 4 \
  --executor-memory "10g"
cde job create \
  --name spark_silver \
  --arg user001 \
  --type spark \
  --mount-1-resource Spark-Files-Shared \
  --application-file 002_Lakehouse_Silver.py \
  --driver-cores 2 \
  --driver-memory "4g" \
  --executor-cores 4 \
  --executor-memory "10g" \
  --python-env-resource-name Python-Env-Shared
cde job create \
  --name spark_gold \
  --arg user001 \
  --type spark \
  --mount-1-resource Spark-Files-Shared \
  --application-file 003_Lakehouse_Gold.py \
  --driver-cores 2 \
  --driver-memory "4g" \
  --executor-cores 4 \
  --executor-memory "10g"

echo "##########################################################"
printf "${fmt}" "CDE ${cde_demo} HOL deployment completed."
printf "${fmt}" "completion time:" "${e}"
printf "${fmt}" "please visit CDE Job Runs UI to view in-progress demo"
echo "##########################################################"