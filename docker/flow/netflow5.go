package main

import "encoding/binary"

// flowRec is one decoded flow record before aggregation.
type flowRec struct {
	srcIP, dstIP     string
	srcPort, dstPort uint16
	proto            uint8
	packets          uint64
	bytes            uint64
	tcpFlags         uint8
	inIf, outIf      uint32
}

// decodeV5 parses a NetFlow v5 packet: 24-byte header + count 48-byte records.
func decodeV5(agg *aggregator, exporter string, pkt []byte) {
	if len(pkt) < 24 {
		return
	}
	count := int(binary.BigEndian.Uint16(pkt[2:4]))
	off := 24
	for i := 0; i < count; i++ {
		if off+48 > len(pkt) {
			return
		}
		r := pkt[off : off+48]
		agg.add(exporter, flowRec{
			srcIP:    ipv4(r[0:4]),
			dstIP:    ipv4(r[4:8]),
			inIf:     uint32(binary.BigEndian.Uint16(r[8:10])),
			outIf:    uint32(binary.BigEndian.Uint16(r[10:12])),
			packets:  uint64(binary.BigEndian.Uint32(r[12:16])),
			bytes:    uint64(binary.BigEndian.Uint32(r[16:20])),
			srcPort:  binary.BigEndian.Uint16(r[24:26]),
			dstPort:  binary.BigEndian.Uint16(r[26:28]),
			tcpFlags: r[29],
			proto:    r[30],
		})
		off += 48
	}
}

func ipv4(b []byte) string {
	return net4String(b[0], b[1], b[2], b[3])
}

func net4String(a, b, c, d byte) string {
	return itoa(int(a)) + "." + itoa(int(b)) + "." + itoa(int(c)) + "." + itoa(int(d))
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var buf [4]byte
	p := len(buf)
	for i > 0 {
		p--
		buf[p] = byte('0' + i%10)
		i /= 10
	}
	return string(buf[p:])
}
