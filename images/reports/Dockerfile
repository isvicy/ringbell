FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/reports .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/reports /reports
EXPOSE 8080
ENTRYPOINT ["/reports"]
