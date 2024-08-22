FROM node:18-bullseye-slim
WORKDIR /workspace
COPY ./package.json ./yarn.lock ./
RUN yarn
COPY ./*.ts ./tsconfig.json ./
RUN mkdir /config
RUN touch /config/l2_chain_info.json
RUN yarn build
ENTRYPOINT ["node", "index.js"]
