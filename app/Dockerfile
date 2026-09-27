# Building the binary of the App (based on tasky's own Dockerfile, kept as
# close to the original as possible - just adding the exercise.txt requirement
# and a non-root user for the release stage)
FROM golang:1.19 AS build

WORKDIR /go/src/tasky
COPY . .
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /go/src/tasky/tasky

FROM alpine:3.17.0 AS release

WORKDIR /app
COPY --from=build /go/src/tasky/tasky .
COPY --from=build /go/src/tasky/assets ./assets

# Exercise requirement: file must exist in the running container, with your name
RUN echo "Your Full Name" > /app/exercise.txt

# Run as non-root (basic hardening, worth mentioning in the demo - the
# original tasky Dockerfile runs as root by default)
RUN addgroup -S appgroup && adduser -S appuser -G appgroup && \
    chown -R appuser:appgroup /app
USER appuser

EXPOSE 8080
ENTRYPOINT ["/app/tasky"]