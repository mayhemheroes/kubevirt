FROM golang:1.24 AS builder
ADD . /kubevirt
WORKDIR /kubevirt
RUN go build -mod=vendor -o /fuzz_admitter ./mayhem/harness/

FROM ubuntu:22.04
COPY --from=builder /fuzz_admitter /fuzz_admitter
