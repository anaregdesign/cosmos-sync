FROM --platform=$BUILDPLATFORM golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/cosmos-sync-bff ./cmd/cosmos-sync-bff
RUN mkdir -p /out/licenses && cp /usr/local/go/LICENSE /out/licenses/Go-LICENSE && \
    find /go/pkg/mod -type f \( -iname LICENSE -o -iname 'LICENSE.*' -o -iname NOTICE -o -iname 'NOTICE.*' -o -iname COPYING \) | \
    while IFS= read -r file; do relative=${file#/go/pkg/mod/}; mkdir -p "/out/licenses/modules/$(dirname "$relative")"; cp "$file" "/out/licenses/modules/$relative"; done

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /out/cosmos-sync-bff /cosmos-sync-bff
COPY --from=build /src/LICENSE /LICENSE
COPY --from=build /out/licenses /licenses
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/cosmos-sync-bff"]
CMD ["-config", "/run/config/config.json"]
