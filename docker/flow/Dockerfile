# owlpane-ndm-flow: NetFlow v5/v9 + IPFIX receiver. Stdlib-only Go, scratch image.
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /flow .

FROM scratch
COPY --from=build /flow /flow
USER 65532
EXPOSE 2055/udp
ENTRYPOINT ["/flow"]
