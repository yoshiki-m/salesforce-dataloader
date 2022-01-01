# Salesforce Dataloader実行image
FROM gcr.io/common-jinzaisystem-tool/gcloud-java:1.8.0

# ディレクトリ作成
RUN mkdir -p /opt/dataloader/bin/lib && \
    mkdir -p /opt/dataloader/conf && \
    mkdir -p /opt/dataloader/data

# イメージにファイル追加
ADD bin /opt/dataloader/bin/
ADD conf /opt/dataloader/conf/

# shファイルに実行権限追加
RUN chmod +x /opt/dataloader/bin/*.sh
