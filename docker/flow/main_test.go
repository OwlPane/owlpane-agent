package main

import (
	"encoding/binary"
	"strings"
	"testing"
)

func v5Packet(recs ...[]byte) []byte {
	pkt := make([]byte, 24)
	binary.BigEndian.PutUint16(pkt[0:2], 5)
	binary.BigEndian.PutUint16(pkt[2:4], uint16(len(recs)))
	for _, r := range recs {
		pkt = append(pkt, r...)
	}
	return pkt
}

func v5Record(src, dst [4]byte, sport, dport uint16, proto byte, pkts, octets uint32, flags byte) []byte {
	r := make([]byte, 48)
	copy(r[0:4], src[:])
	copy(r[4:8], dst[:])
	binary.BigEndian.PutUint32(r[12:16], pkts)
	binary.BigEndian.PutUint32(r[16:20], octets)
	binary.BigEndian.PutUint16(r[24:26], sport)
	binary.BigEndian.PutUint16(r[26:28], dport)
	r[29] = flags
	r[30] = proto
	return r
}

func TestDecodeV5(t *testing.T) {
	agg := newAggregator(map[string]string{"10.0.0.1": "core-sw"})
	pkt := v5Packet(
		v5Record([4]byte{192, 168, 1, 10}, [4]byte{10, 0, 0, 5}, 51234, 443, 6, 100, 150000, 0x18), // PSH+ACK
		v5Record([4]byte{192, 168, 1, 10}, [4]byte{10, 0, 0, 5}, 51234, 443, 6, 50, 75000, 0x10),   // ACK
		v5Record([4]byte{8, 8, 8, 8}, [4]byte{192, 168, 1, 10}, 53, 10500, 17, 4, 900, 0),
	)
	decodeV5(agg, "10.0.0.1", pkt)
	if len(agg.flows) != 2 {
		t.Fatalf("expected 2 conversations, got %d", len(agg.flows))
	}
	out := agg.drain()
	if !strings.Contains(out, `"owlpane.ndm.device","value":{"stringValue":"core-sw"}`) {
		t.Errorf("exporter IP not mapped to device name:\n%s", out)
	}
	// Same conversation twice: bytes must sum (150000 + 75000).
	if !strings.Contains(out, `"owlpane.ndm.flow.bytes","value":{"stringValue":"225000"}`) {
		t.Errorf("bytes not aggregated:\n%s", out)
	}
	if !strings.Contains(out, `"owlpane.ndm.flow.tcp_flags","value":{"stringValue":"PSH,ACK"}`) {
		t.Errorf("tcp flags not decoded/merged:\n%s", out)
	}
	if !strings.Contains(out, `"owlpane.ndm.flow.protocol","value":{"stringValue":"UDP"}`) {
		t.Errorf("protocol name missing:\n%s", out)
	}
	// Drain resets the window.
	if agg.drain() != "" {
		t.Error("drain did not reset")
	}
}

func TestDecodeV5UnknownExporter(t *testing.T) {
	agg := newAggregator(nil)
	decodeV5(agg, "172.16.0.9", v5Packet(v5Record([4]byte{1, 1, 1, 1}, [4]byte{2, 2, 2, 2}, 1, 2, 6, 1, 64, 0x02)))
	out := agg.drain()
	if !strings.Contains(out, `"owlpane.ndm.device","value":{"stringValue":"172.16.0.9"}`) {
		t.Errorf("unknown exporter should fall back to its IP:\n%s", out)
	}
	if !strings.Contains(out, `"stringValue":"SYN"`) {
		t.Errorf("SYN flag missing:\n%s", out)
	}
}

// v9: one template (srcIPv4, dstIPv4, srcPort, dstPort, proto, bytes, pkts, flags) + one data set.
func v9Packet() []byte {
	hdr := make([]byte, 20)
	binary.BigEndian.PutUint16(hdr[0:2], 9)
	binary.BigEndian.PutUint16(hdr[2:4], 1)
	binary.BigEndian.PutUint32(hdr[16:20], 7) // source id

	tpl := make([]byte, 4)
	binary.BigEndian.PutUint16(tpl[0:2], 256) // template id
	binary.BigEndian.PutUint16(tpl[2:4], 8)   // field count
	for _, f := range [][2]uint16{{8, 4}, {12, 4}, {7, 2}, {11, 2}, {4, 1}, {1, 4}, {2, 4}, {6, 1}} {
		var b [4]byte
		binary.BigEndian.PutUint16(b[0:2], f[0])
		binary.BigEndian.PutUint16(b[2:4], f[1])
		tpl = append(tpl, b[:]...)
	}
	tplSet := make([]byte, 4)
	binary.BigEndian.PutUint16(tplSet[0:2], 0) // template flowset
	binary.BigEndian.PutUint16(tplSet[2:4], uint16(4+len(tpl)))
	tplSet = append(tplSet, tpl...)

	rec := []byte{10, 0, 0, 20, 203, 0, 113, 50, 0, 80, 0, 25, 6, 0, 0, 0x0d, 0x40, 0, 0, 0, 40, 0x12}
	dataSet := make([]byte, 4)
	binary.BigEndian.PutUint16(dataSet[0:2], 256)
	binary.BigEndian.PutUint16(dataSet[2:4], uint16(4+len(rec)))
	dataSet = append(dataSet, rec...)

	return append(append(hdr, tplSet...), dataSet...)
}

func TestDecodeV9(t *testing.T) {
	agg := newAggregator(map[string]string{"10.0.0.1": "edge-rtr"})
	decodeV9(agg, "10.0.0.1", v9Packet(), false)
	out := agg.drain()
	for _, want := range []string{
		`"owlpane.ndm.flow.src.ip","value":{"stringValue":"10.0.0.20"}`,
		`"owlpane.ndm.flow.dst.ip","value":{"stringValue":"203.0.113.50"}`,
		`"owlpane.ndm.flow.dst.port","value":{"stringValue":"25"}`,
		`"owlpane.ndm.flow.bytes","value":{"stringValue":"3392"}`,
		`"owlpane.ndm.flow.packets","value":{"stringValue":"40"}`,
		`"owlpane.ndm.flow.tcp_flags","value":{"stringValue":"SYN,ACK"}`,
		`"owlpane.ndm.device","value":{"stringValue":"edge-rtr"}`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s in:\n%s", want, out)
		}
	}
}

func TestV9DataBeforeTemplateDropped(t *testing.T) {
	agg := newAggregator(nil)
	pkt := v9Packet()
	// Reorder: data set before template set is not how v9Packet builds it, so instead
	// decode only the data portion against a fresh template cache.
	templates.Lock()
	templates.m = map[string]map[uint16]template{}
	templates.Unlock()
	hdr := pkt[:20]
	// data set starts after header + template set
	tplLen := int(binary.BigEndian.Uint16(pkt[22:24]))
	data := pkt[20+tplLen:]
	decodeV9(agg, "10.9.9.9", append(hdr, data...), false)
	if out := agg.drain(); out != "" {
		t.Errorf("data without template must be dropped, got:\n%s", out)
	}
}

func TestIPFIXHeader(t *testing.T) {
	// Same body as v9 but IPFIX header (16 bytes) and template set id 2.
	v9 := v9Packet()
	body := v9[20:]
	// rewrite template set id 0 -> 2
	binary.BigEndian.PutUint16(body[0:2], 2)
	hdr := make([]byte, 16)
	binary.BigEndian.PutUint16(hdr[0:2], 10)
	binary.BigEndian.PutUint16(hdr[2:4], uint16(16+len(body)))
	binary.BigEndian.PutUint32(hdr[12:16], 3) // observation domain
	agg := newAggregator(nil)
	decodeV9(agg, "10.0.0.1", append(hdr, body...), true)
	out := agg.drain()
	if !strings.Contains(out, `"stringValue":"203.0.113.50"`) {
		t.Errorf("IPFIX decode failed:\n%s", out)
	}
}

func TestPostLogsEnvelope(t *testing.T) {
	// No server: just verify the request builder errors cleanly without endpoint.
	if err := postLogs("", "k", "c", "e", "{}"); err == nil {
		t.Error("expected error for empty endpoint")
	}
}
