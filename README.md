# salesforce-dataloader

# 概要
Salesforce Dataloaderを使い、SalesforceのオブジェクトデータをBigQueryにロードする。  
コンテナの実行はAirflowで行う前提で設計されている。

# ローカルでの実行、テスト手順

Docker for Windows + Git Bash で動きます。

## サービスアカウント認証ファイルを作成

`salesforce-dataloader/tests` 配下にサービスアカウントKeyファイルを配置しておく（Git管理外）

## コンテナ起動

```bash
TEST_IMAGE=[ローカルで実行するDockerイメージID]
HOST_BASE_DIR=[jinzaibank-gcp-dockerをクローンしたディレクトリのフルパス]/salesforce-dataloader

SERVICE_ACCOUNT_CREDENTIALS=$(cat $HOST_BASE_DIR/tests/[サービスアカウントKeyファイル]| base64)

# コンテナの中に入る
docker run --rm -i -t \
    -v $HOST_BASE_DIR/bin:/opt/dataloader/bin \
    -v $HOST_BASE_DIR/data:/opt/dataloader/data \
    -v $HOST_BASE_DIR/tests:/opt/dataloader/tests \
    -e SERVICE_ACCOUNT_CREDENTIALS="$SERVICE_ACCOUNT_CREDENTIALS" \
    $TEST_IMAGE
```    

## コンテナ内でテスト実行

```bash
export PROJECT_ID=dev-jinzaisystem-tool

# environment: 環境 sandbox or production
environment=sandbox
# entity: SFのオブジェクトのAPI参照名
entity=area__c # 例
# entity: BigQueryのテーブル名
table_name=area__c # 例
# gcs_config_file_folder: GCS上の設定ファイルが存在するフォルダのパス (ex. gs://bucket/folder)
gcs_config_file_folder=gs://asia-northeast1-dev-jinzais-a068ddd9-bucket/dags/common
# target_date: 日付(YYYYMMDD)
target_date=$(date '+%Y%m%d' --date '1 day ago')

# シェル実行
/opt/dataloader/bin/execute.sh $environment $entity $table_name $gcs_config_file_folder $target_date

```