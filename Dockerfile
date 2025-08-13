
FROM ghcr.io/open-webui/open-webui:latest

EXPOSE 8080

COPY sync_data.sh sync_data.sh  

RUN chmod -R 777 ./data && \  
    sed -i "1r sync_data.sh" ./start.sh  
