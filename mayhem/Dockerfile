FROM golang:1.24 AS builder
ADD . /kubevirt
WORKDIR /kubevirt
RUN go test -c -mod=vendor -o /fuzz_admitter ./pkg/virt-api/webhooks/fuzz/

FROM ubuntu:22.04
COPY --from=builder /fuzz_admitter /fuzz_admitter
