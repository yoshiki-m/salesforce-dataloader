#!/bin/bash
##############################################################
#
# SalesforceのDataloaderを実行し、csv.gzファイルを作成し、A&I所有のAWS S3に連携する。
# Kubernetes上で実行する前提であるため、リトライはAirflow側で制御する。
# GCP、AWSへの接続はリトライ回数実行し、
# 主処理であるSFへの接続のリトライはこのスクリプトでは行わない。
#
# Args:
#    entity: SFのオブジェクトのAPI参照名
#    gcs_config_file_folder: GCS上の設定ファイルが存在するフォルダのパス (ex. gs://bucket/folder)
#    s3_uri: 送信先AWS S3のURI
#
# Returns:
#    0: 正常終了
#    -1: 異常終了
#
##############################################################

# 引数展開
entity=${1}
gcs_config_file_folder=${2}
s3_uri=${3}

# 定数
SF_ENVIRONMENT=production
CONFIG_DIR=/opt/dataloader/conf
DATALOADER_JAR=/opt/dataloader/bin/lib/dataloader-43.0.0-uber.jar
DATALOADER_CONFIG=${CONFIG_DIR}/process-conf.xml

# デフォルトのリトライ設定(設定ファイルで上書きする)
RETRY_MAX=3
RETRY_INTERVAL=10
TIMEOUT_SECOND=7200


# ログ設定
stdout_err=/var/tmp/stdout_err
stdout_err_1=/var/tmp/stdout_err_1
stdout_err_2=/var/tmp/stdout_err_2
stdout_err_3=/var/tmp/stdout_err_3

##############################################################
# GCSからファイルをダウンロードする関数
# Args:
#    gcs_file_path: ダウンロードするファイルのパス (ex. gs://bucket/folder/filename)
#    local_dir: ダウンロード先のディレクトリ (ex. /var/tmp)
##############################################################
function download_file_from_gcs () {
    # 引数設定
    gcs_file_path=${1}
    local_dir=${2}

    try_count=0
    ret=1
    skip=0
    
    log_message="0) download config file from GCS: ${gcs_file_path}"
    echo ${log_message}
    while :
    do
        if [ ${skip} -eq 1 ]; then break; fi
        gsutil cp ${gcs_file_path} ${local_dir}/ 1>${stdout_err} 2>&1
        ret=${?}
        if [ ${ret} -eq 0 ]; then
            break
        else
            echo "${log_message} failure ! `echo ${stdout_err}`"
        fi

        if [ ${try_count} -ge ${RETRY_MAX} ]; then
           echo "Error! download config file from GCS `echo ${stdout_err}`"
           exit -1
        fi
        sleep ${RETRY_INTERVAL}
        try_count=$(( try_count + 1 ))
    done
}

##############################################################
# GCPサービスアカウント認証
##############################################################
# KubernetesのSecretから認証情報を取得
echo ${SERVICE_ACCOUNT_CREDENTIALS} | base64 --decode > ${CONFIG_DIR}/gcp_credentials.json

# 認証
gcloud auth activate-service-account --key-file ${CONFIG_DIR}/gcp_credentials.json

##############################################################
# 設定ファイル取得
##############################################################
# キーファイル・envファイル・sqlファイルをGCSから取得
download_file_from_gcs ${gcs_config_file_folder}/config/dataloader/${SF_ENVIRONMENT}.key ${CONFIG_DIR}
download_file_from_gcs ${gcs_config_file_folder}/config/dataloader/${SF_ENVIRONMENT}.env ${CONFIG_DIR}
download_file_from_gcs ${gcs_config_file_folder}/sql/sf/${entity}.sql ${CONFIG_DIR}

# 設定ファイル読み込み
. ${CONFIG_DIR}/${SF_ENVIRONMENT}.env

# プロジェクト設定
gcloud config set project ${PROJECT_ID}

##############################################################
# Dataloader実行
##############################################################
output_file=${entity}.csv

# SOQLの特殊文字をエスケープ
sed -i "s/</\\&lt;/g"  ${CONFIG_DIR}/${entity}.sql
sed -i "s/>/\\&gt;/g"  ${CONFIG_DIR}/${entity}.sql
sed -i "s/\&/\\\&/g"  ${CONFIG_DIR}/${entity}.sql
# SOQLを変数にセット
soql=`cat ${CONFIG_DIR}/${entity}.sql`

# Dataloader設定ファイルの置換文字列を置換
sed -i "s|<ENDPOINT>|${ENDPOINT}|g" ${DATALOADER_CONFIG}
sed -i "s/<USERNAME>/${USERNAME}/g" ${DATALOADER_CONFIG}
sed -i "s/<PASSWORD>/${PASSWORD}/g" ${DATALOADER_CONFIG}
sed -i "s|<ENCRYPTIONKEYFILE>|${CONFIG_DIR}/${SF_ENVIRONMENT}.key|g" ${DATALOADER_CONFIG}
sed -i "s/<ENTITY>/${entity}/g" ${DATALOADER_CONFIG}
sed -i "s/<SOQL>/`echo ${soql}`/g" ${DATALOADER_CONFIG}
sed -i "s/<OUTPUTFILE>/${output_file}/g" ${DATALOADER_CONFIG}

ret=1
log_message="1) get sf data"
echo ${log_message}
retry_interval_second=${RETRY_INTERVAL}

# SF接続
cd /opt/dataloader/data
timeout -k 5 ${TIMEOUT_SECOND} java -mx1024m -XX:+HeapDumpOnOutOfMemoryError -cp ${DATALOADER_JAR} \
        -Dsalesforce.config.dir=${CONFIG_DIR}/ \
        -Dfile.encoding=UTF8 \
        com.salesforce.dataloader.process.ProcessRunner process.name=exportCO 1>${stdout_err_1} 2>&1
ret=${?}
if [ ${ret} -eq 0 ]; then
    # ファイルが作成されていない場合、異常終了
    if [ ! -f ${output_file} ]; then
        echo "${log_message} failure ! Download file is not found"
        exit -1
    else
        # データ件数確認
        CSV_WC=`wc -l ${output_file}`
        CSV_ROW=`expr ${CSV_WC% *}`
        echo ${CSV_ROW}
        # データが取得できていない場合、異常終了
        if [ 2 -gt ${CSV_ROW} ]; then
            echo "${log_message} failure ! Download file is header only"
            exit -1
        fi
    fi
else
    # Javaがエラーコードを返した場合、異常終了
    echo "${log_message} failure ! Java Failure or Timeout `cat ${stdout_err_1}`"
    exit -1
fi

# 圧縮
gzip -f ${output_file}

##############################################################
# AWS S3にロード
##############################################################
echo ${output_file}
echo ${s3_uri}

# botoファイル作成
sed -i "s|<AWS_ACCESS_KEY_ID>|${AWS_ACCESS_KEY_ID}|g" ${CONFIG_DIR}/boto.txt
sed -i "s|<AWS_SECRET_ACCESS_KEY>|${AWS_SECRET_ACCESS_KEY}|g" ${CONFIG_DIR}/boto.txt
sed -i "s|<AWS_S3_ENDPOINT>|${AWS_S3_ENDPOINT}|g" ${CONFIG_DIR}/boto.txt
cp ${CONFIG_DIR}/boto.txt /root/.boto

try_count=0
ret=1
log_message="2) send to AWS S3"
skip=0
echo ${log_message}
while :
do
    if [ ${skip} -eq 1 ]; then break; fi
    # アップロード
    gsutil cp ${output_file}.gz ${s3_uri}/${output_file}.gz 1>${stdout_err_2} 2>&1
    ret=${?}
    if [ ${ret} -eq 0 ]; then
        break
    else
        echo "${log_message} failure ! `cat ${stdout_err_2}`"
    fi

    if [ ${try_count} -ge ${RETRY_MAX} ]; then
        # 異常終了
        echo "Error! upload to AWS S3 `cat ${stdout_err_2}`"
        exit -1
    fi
    sleep ${RETRY_INTERVAL}
    try_count=$(( try_count + 1 ))
done
