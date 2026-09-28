// Command owlpane-flow receives NetFlow v5/v9 and IPFIX datagrams over UDP, aggregates
// them per conversation, and posts OTLP log records (owlpane.ndm.flow.*) to Owlpane.
// Stdlib only — the image must stay tiny and auditable.
package main

import (
	"log"
	"net"
	"os"
	"strconv"
	"time"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	port, err := strconv.Atoi(env("FLOW_PORT", "2055"))
	if err != nil || port < 1 || port > 65535 {
		log.Fatalf("flow: bad FLOW_PORT %q", os.Getenv("FLOW_PORT"))
	}
	interval, err := strconv.Atoi(env("FLOW_INTERVAL", "60"))
	if err != nil || interval < 5 {
		interval = 60
	}
	key := os.Getenv("OWLPANE_INGEST_KEY")
	if key == "" {
		log.Fatal("flow: missing OWLPANE_INGEST_KEY")
	}

	// Exporter IP -> device name, from the same NDM_DEV_<i>_NAME/HOST env the poller uses.
	devices := map[string]string{}
	for i := 1; i <= 64; i++ {
		name := os.Getenv("NDM_DEV_" + strconv.Itoa(i) + "_NAME")
		host := os.Getenv("NDM_DEV_" + strconv.Itoa(i) + "_HOST")
		if name == "" || host == "" {
			if name == "" {
				break
			}
			continue
		}
		devices[host] = name
	}

	agg := newAggregator(devices)
	addr := &net.UDPAddr{Port: port}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Fatalf("flow: listen :%d: %v", port, err)
	}
	log.Printf("flow: listening on udp/%d, flushing every %ds, %d device mappings", port, interval, len(devices))

	go func() {
		t := time.NewTicker(time.Duration(interval) * time.Second)
		for range t.C {
			payload := agg.drain()
			if payload == "" {
				continue
			}
			if err := postLogs(env("ENDPOINT", ""), key, env("CLUSTER", ""), env("ENVNAME", ""), payload); err != nil {
				log.Printf("flow: post failed: %v", err)
			}
		}
	}()

	buf := make([]byte, 65535)
	for {
		n, src, err := conn.ReadFromUDP(buf)
		if err != nil {
			log.Printf("flow: read: %v", err)
			continue
		}
		if n < 4 {
			continue
		}
		pkt := buf[:n]
		switch v := int(pkt[0])<<8 | int(pkt[1]); v {
		case 5:
			decodeV5(agg, src.IP.String(), pkt)
		case 9:
			decodeV9(agg, src.IP.String(), pkt, false)
		case 10:
			decodeV9(agg, src.IP.String(), pkt, true)
		}
	}
}
