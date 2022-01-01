#!/bin/bash
##############################################################
#
# SalesforceのDataloaderを実行し、csv.gzファイルをGCSに出力し、BigQueryにロードする。
# Kubernetes上で実行する前提であるため、リトライはAirflow側で制御する。
# GCPへの接続はリトライ回数実行し、
# 主処理であるSFへの接続のリトライはこのスクリプトでは行わない。
#
# Args:
#    environment: 環境 sandbox or production
#    entity: SFのオブジェクトのAPI参照名
#    table_name: BigQueryのテーブル名
#    gcs_config_file_folder: GCS上の設定ファイルが存在するフォルダのパス (ex. gs://bucket/folder)
#    target_date: 日付(YYYYMMDD)
#
# Returns:
#    0: 正常終了
#    -1: 異常終了
#
##############################################################
echo "[START] execute.sh"
# 引数展開
environment=${1}
entity=${2}
table_name=${3}
gcs_config_file_folder=${4}
target_date=${5}

# 定数
CONFIG_DIR=/opt/dataloader/conf
DATALOADER_JAR=/opt/dataloader/bin/lib/dataloader-43.0.0-uber.jar
DATALOADER_CONFIG=${CONFIG_DIR}/process-conf.xml
DATASET=salesforce

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
    retry_interval_second=${RETRY_INTERVAL}
    
    log_message="[INFO] GCSのファイルをダウンロードします: ${gcs_file_path}"
    echo ${log_message}
    while :
    do
        if [ ${skip} -eq 1 ]; then break; fi
        gsutil cp ${gcs_file_path} ${local_dir}/ 1>${stdout_err} 2>&1
        ret=${?}
        if [ ${ret} -eq 0 ]; then
            break
        else
            echo "${log_message} failure ! `cat ${stdout_err}`"
        fi

        if [ ${try_count} -ge ${RETRY_MAX} ]; then
           echo "Error! download config file from GCS `cat ${stdout_err}`"
           echo "[END] execute.sh 異常終了"
           exit -1
        fi
        sleep ${retry_interval_second}
        try_count=$(( try_count + 1 ))
    done
}

##############################################################
# GCPサービスアカウント認証
##############################################################
echo "[START] GCPサービスアカウント認証"
# KubernetesのSecretから認証情報を取得
echo "${SERVICE_ACCOUNT_CREDENTIALS}" | base64 --decode > ${CONFIG_DIR}/gcp_credentials.json
gcloud auth activate-service-account --key-file ${CONFIG_DIR}/gcp_credentials.json
echo "[END] GCPサービスアカウント認証"
##############################################################
# 設定ファイル取得
##############################################################
echo "[START] 設定ファイル取得"
# キーファイル・envファイル・sqlファイルをGCSから取得
download_file_from_gcs ${gcs_config_file_folder}/config/dataloader/${environment}.key ${CONFIG_DIR}
download_file_from_gcs ${gcs_config_file_folder}/config/dataloader/${environment}.env ${CONFIG_DIR}
download_file_from_gcs ${gcs_config_file_folder}/sql/sf/${table_name}.sql ${CONFIG_DIR}
echo "[END] 設定ファイル取得"

echo "[START] プロジェクト設定"
# 設定ファイル読み込み
. ${CONFIG_DIR}/${environment}.env
# プロジェクト設定
gcloud config set project ${PROJECT_ID}
echo "[END] プロジェクト設定"

##############################################################
# Dataloader設定ファイル作成
##############################################################
echo "[START] Dataloader設定ファイル作成"
output_file=${table_name}_${target_date}.csv

# SOQLの特殊文字をエスケープ
sed -i "s/</\\&lt;/g"  ${CONFIG_DIR}/${table_name}.sql
sed -i "s/>/\\&gt;/g"  ${CONFIG_DIR}/${table_name}.sql
sed -i "s/\&/\\\&/g"  ${CONFIG_DIR}/${table_name}.sql
# SOQLを変数にセット
soql=`cat ${CONFIG_DIR}/${table_name}.sql`

# Dataloader設定ファイルの置換文字列を置換
sed -i "s|<ENDPOINT>|${ENDPOINT}|g" ${DATALOADER_CONFIG}
sed -i "s/<USERNAME>/${USERNAME}/g" ${DATALOADER_CONFIG}
sed -i "s/<PASSWORD>/${PASSWORD}/g" ${DATALOADER_CONFIG}
sed -i "s|<ENCRYPTIONKEYFILE>|${CONFIG_DIR}/${environment}.key|g" ${DATALOADER_CONFIG}
sed -i "s/<ENTITY>/${entity}/g" ${DATALOADER_CONFIG}
sed -i "s/<SOQL>/`echo ${soql}`/g" ${DATALOADER_CONFIG}
sed -i "s/<OUTPUTFILE>/${output_file}/g" ${DATALOADER_CONFIG}
echo "[END] Dataloader設定ファイル作成"

##############################################################
# Dataloader実行
# 
# 想定しうるコマンドのレスポンスパターン
# - 正常終了（0件以上）: ステータスが0
# - 正常終了（0件）: ステータスが0 (0件でファイルが作成される)
# - SOQL構文エラー: ステータスが0 (0件でファイルが作成される)
# - SF接続失敗: ステータスが255
# - タイムアウト: ステータスが124
##############################################################
echo "[START] DataloaderでSOQL実行"
cd /opt/dataloader/data

# Dataloader実行
command_log="$(timeout -k 5 ${TIMEOUT_SECOND} java -mx1024m -XX:+HeapDumpOnOutOfMemoryError -cp ${DATALOADER_JAR} \
        -Dsalesforce.config.dir=${CONFIG_DIR}/ \
        -Dfile.encoding=UTF8 \
        com.salesforce.dataloader.process.ProcessRunner process.name=exportCO)"
command_status=${?}
echo "[INFO] java実行ステータス: $command_status"
echo "[INFO] java実行ログ"
echo "$command_log"
echo "[END] DataloaderでSOQL実行"

echo "[START] Dataloaderの出力結果を確認"
# 異常終了判定
if [ ${command_status} -eq 124 ]; then
    # 終了ステータスが124の場合は、タイムアウト、異常終了する
    echo "[ERROR] Dataloaderの実行がタイムアウトアウトしました。タイムアウト時間: $TIMEOUT_SECOND"
    echo "[END] execute.sh 異常終了"
    exit -1
elif [ ${command_status} -ne 0 ]; then
    # Javaが0以外のエラーコードを返した場合、異常終了する
    echo "[ERROR] Dataloaderの実行が失敗しました。 Java終了ステータス: ${command_status}"
    echo "[END] execute.sh 異常終了"
    exit -1
elif [ $(echo "$command_log" | grep -c ERROR) -gt 0 ]; then
    # コマンドのログにERRORという文字が1つでもあれば、異常終了する
    echo "[ERROR] Dataloaderの実行が失敗しました。 Java終了ステータス: ${command_status}"
    echo "[END] execute.sh 異常終了"
    exit -1
fi
# 出力ファイルの件数確認
output_file_wc=$(wc -l ${output_file})
output_file_csv_row=$(expr ${output_file_wc% *})
echo "[INFO] 出力件数: $output_file_csv_row"
if [ 2 -gt ${output_file_csv_row} ]; then
    echo "[WARNING] SOQLの実行結果が0件です(header only)"
    echo "[END] execute.sh 正常終了"
    exit 0
fi
echo "[END] Dataloaderの出力結果を確認"

##############################################################
# 圧縮してGCSにアップロード
##############################################################
echo "[START] 圧縮してGCSにアップロード"
try_count=0
ret=1
skip=0
retry_interval_second=${RETRY_INTERVAL}
while :
do
    if [ ${skip} -eq 1 ]; then break; fi
    # 圧縮
    gzip -f ${output_file}
    # アップロード
    gsutil -h "Content-Type: application/gzip" \
	   cp ${output_file}.gz ${OUTPUT_GCS_BUCKET}/${target_date}/${output_file}.gz \
	   1>${stdout_err_2} 2>&1
    ret=${?}
    if [ ${ret} -eq 0 ]; then
        break
    else
        echo "[WARNING] GCSへのアップロードが失敗しました。 `cat ${stdout_err_2}`"
    fi

    if [ ${try_count} -ge ${RETRY_MAX} ]; then
        echo "[ERROR] GCSへのアップロードがリトライ回数失敗しました。 `cat ${stdout_err_2}`"
        echo "[END] execute.sh 異常終了"
        exit -1
    fi
    sleep ${retry_interval_second}
    try_count=$(( try_count + 1 ))
    retry_interval_second=$(( retry_interval_second * 2 ))
done
echo "[END] 圧縮してGCSにアップロード"

##############################################################
# BigQueryにデータをロード
##############################################################
echo "[START] BigQueryにデータをロード"
try_count=0
ret=1
skip=0
retry_interval_second=${RETRY_INTERVAL}
while :
do
    if [ ${skip} -eq 1 ]; then break; fi
    # BigQueryにロード
    # 予めパーティションテーブルとして作成しておく必要がある。
    bq load --replace --skip_leading_rows 1 --allow_quoted_newlines \
	    ${DATASET}.${table_name}\$${target_date} \
	    ${OUTPUT_GCS_BUCKET}/${target_date}/${output_file}.gz 1>${stdout_err_3} 2>&1

    ret=${?}
    if [ ${ret} -eq 0 ]; then
        break
    else
        echo "[WARNING] BigQueryのロードが失敗しました。 `cat ${stdout_err_3}`"
    fi

    if [ ${try_count} -ge ${RETRY_MAX} ]; then
        echo "[ERROR] BigQueryのロードがリトライ回数失敗しました。 `cat ${stdout_err_3}`"
        echo "[END] execute.sh 異常終了"
        exit -1
    fi
    sleep ${retry_interval_second}
    try_count=$(( try_count + 1 ))
    retry_interval_second=$(( retry_interval_second * 2 ))
done
echo "[END] BigQueryにデータをロード"

# 正常終了
echo "[END] execute.sh 正常終了"
exit 0