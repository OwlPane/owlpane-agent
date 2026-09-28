package main

import (
	"bytes"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// aggregator accumulates flows per conversation between flushes.
type aggregator struct {
	mu      sync.Mutex
	devices map[string]string // exporter IP -> device name
	flows   map[string]*aggFlow
}

type aggFlow struct {
	device, srcIP, dstIP string
	srcPort, dstPort     uint16
	proto                uint8
	packets, bytes       uint64
	tcpFlags             uint8
}

func newAggregator(devices map[string]string) *aggregator {
	return &aggregator{devices: devices, flows: map[string]*aggFlow{}}
}

var protoNames = map[uint8]string{1: "ICMP", 6: "TCP", 17: "UDP", 47: "GRE", 50: "ESP", 58: "ICMPv6", 89: "OSPF"}

func protoName(p uint8) string {
	if n, ok := protoNames[p]; ok {
		return n
	}
	return strconv.Itoa(int(p))
}

func (a *aggregator) add(exporter string, r flowRec) {
	dev := a.devices[exporter]
	if dev == "" {
		dev = exporter
	}
	key := strings.Join([]string{dev, r.srcIP, r.dstIP,
		strconv.Itoa(int(r.srcPort)), strconv.Itoa(int(r.dstPort)), strconv.Itoa(int(r.proto))}, "|")
	a.mu.Lock()
	f := a.flows[key]
	if f == nil {
		f = &aggFlow{device: dev, srcIP: r.srcIP, dstIP: r.dstIP, srcPort: r.srcPort, dstPort: r.dstPort, proto: r.proto}
		a.flows[key] = f
	}
	f.packets += r.packets
	f.bytes += r.bytes
	f.tcpFlags |= r.tcpFlags
	a.mu.Unlock()
}

// drain returns the OTLP logRecords JSON array for accumulated flows and resets the window.
func (a *aggregator) drain() string {
	a.mu.Lock()
	flows := a.flows
	a.flows = map[string]*aggFlow{}
	a.mu.Unlock()
	if len(flows) == 0 {
		return ""
	}
	now := strconv.FormatInt(time.Now().UnixNano(), 10)
	var b strings.Builder
	for _, f := range flows {
		fmt.Fprintf(&b, `{"timeUnixNano":"%s","severityText":"INFO","body":{"stringValue":"ndm flow"},"attributes":[`, now)
		attr := func(k, v string) {
			fmt.Fprintf(&b, `{"key":"%s","value":{"stringValue":"%s"}},`, k, v)
		}
		attr("owlpane.ndm.kind", "flow")
		attr("owlpane.ndm.device", f.device)
		attr("owlpane.ndm.flow.src.ip", f.srcIP)
		attr("owlpane.ndm.flow.src.port", strconv.Itoa(int(f.srcPort)))
		attr("owlpane.ndm.flow.dst.ip", f.dstIP)
		attr("owlpane.ndm.flow.dst.port", strconv.Itoa(int(f.dstPort)))
		attr("owlpane.ndm.flow.protocol", protoName(f.proto))
		attr("owlpane.ndm.flow.bytes", strconv.FormatUint(f.bytes, 10))
		attr("owlpane.ndm.flow.packets", strconv.FormatUint(f.packets, 10))
		if f.proto == 6 {
			attr("owlpane.ndm.flow.tcp_flags", tcpFlags(f.tcpFlags))
		}
		b.WriteString(`]},`)
	}
	return strings.TrimSuffix(b.String(), ",")
}

func tcpFlags(f uint8) string {
	var s []string
	if f&0x02 != 0 {
		s = append(s, "SYN")
	}
	if f&0x01 != 0 {
		s = append(s, "FIN")
	}
	if f&0x04 != 0 {
		s = append(s, "RST")
	}
	if f&0x08 != 0 {
		s = append(s, "PSH")
	}
	if f&0x10 != 0 {
		s = append(s, "ACK")
	}
	if f&0x20 != 0 {
		s = append(s, "URG")
	}
	return strings.Join(s, ",")
}

// postLogs wraps logRecords in the OTLP/JSON resourceLogs envelope and POSTs it.
func postLogs(endpoint, key, cluster, envName, records string) error {
	if endpoint == "" {
		return fmt.Errorf("ENDPOINT not set")
	}
	body := `{"resourceLogs":[{"resource":{"attributes":[` +
		`{"key":"service.name","value":{"stringValue":"owlpane-ndm-flow"}},` +
		`{"key":"k8s.cluster.name","value":{"stringValue":"` + cluster + `"}},` +
		`{"key":"deployment.environment.name","value":{"stringValue":"` + envName + `"}}` +
		`]},"scopeLogs":[{"scope":{"name":"owlpane-ndm-flow"},"logRecords":[` + records + `]}]}]}`
	req, err := http.NewRequest(http.MethodPost, strings.TrimSuffix(endpoint, "/")+"/v1/logs", bytes.NewBufferString(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}
