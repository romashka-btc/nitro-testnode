FROM node:16-bullseye-slim
RUN apt-get update && \
    apt-get install -y git docker.io
WORKDIR /workspace  
RUN git clone --depth 1 -b main https://github.com/EspressoSystems/arbitrum-sdk.git ./
RUN yarn install
ENTRYPOINT ["yarn"]
