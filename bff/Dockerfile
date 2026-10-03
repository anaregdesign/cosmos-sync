FROM golang:1.26.5-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/cosmos-sync-bff ./cmd/cosmos-sync-bff

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/cosmos-sync-bff /cosmos-sync-bff
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/cosmos-sync-bff"]
CMD ["-config", "/run/config/config.json"]
