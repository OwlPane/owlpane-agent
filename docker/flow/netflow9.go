package main

import (
	"encoding/binary"
	"net"
	"sync"
)

// NetFlow v9 / IPFIX template-based decoding. Templates are cached per (exporter, sourceID,
// templateID); a data FlowSet whose template hasn't arrived yet is dropped (the exporter
// re-sends templates periodically, so this self-heals).

type templateField struct {
	typ        uint16
	length     uint16
	enterprise bool
}

type template struct {
	fields []templateField
}

var templates = struct {
	sync.Mutex
	m map[string]map[uint16]template
}{m: map[string]map[uint16]template{}}

// Field type IDs we read (v9 and IPFIX share these for the basics).
const (
	fInBytes   = 1
	fInPkts    = 2
	fProtocol  = 4
	fTcpFlags  = 6
	fSrcPort   = 7
	fSrcIPv4   = 8
	fInputIf   = 10
	fDstPort   = 11
	fDstIPv4   = 12
	fOutputIf  = 14
	fSrcIPv6   = 27
	fDstIPv6   = 28
	fFlowStart = 22
)

func decodeV9(agg *aggregator, exporter string, pkt []byte, ipfix bool) {
	var off, setBase int
	var sourceID uint32
	if ipfix {
		if len(pkt) < 16 {
			return
		}
		sourceID = binary.BigEndian.Uint32(pkt[12:16])
		off = 16
		setBase = 2 // IPFIX template set id
	} else {
		if len(pkt) < 20 {
			return
		}
		sourceID = binary.BigEndian.Uint32(pkt[16:20])
		off = 20
		setBase = 0 // v9 template flowset id
	}
	scope := exporter + "/" + itoa(int(sourceID))

	for off+4 <= len(pkt) {
		setID := binary.BigEndian.Uint16(pkt[off : off+2])
		setLen := int(binary.BigEndian.Uint16(pkt[off+2 : off+4]))
		if setLen < 4 || off+setLen > len(pkt) {
			return
		}
		body := pkt[off+4 : off+setLen]
		switch {
		case setID == uint16(setBase): // template set
			parseTemplates(scope, body, ipfix)
		case setID >= 256: // data set
			parseDataSet(agg, exporter, scope, setID, body)
		}
		off += setLen
	}
}

func parseTemplates(scope string, body []byte, ipfix bool) {
	for off := 0; off+4 <= len(body); {
		id := binary.BigEndian.Uint16(body[off : off+2])
		count := int(binary.BigEndian.Uint16(body[off+2 : off+4]))
		off += 4
		t := template{}
		ok := true
		for i := 0; i < count; i++ {
			if off+4 > len(body) {
				ok = false
				break
			}
			typ := binary.BigEndian.Uint16(body[off : off+2])
			ln := binary.BigEndian.Uint16(body[off+2 : off+4])
			off += 4
			f := templateField{typ: typ & 0x7fff, length: ln, enterprise: typ&0x8000 != 0}
			if f.enterprise {
				if off+4 > len(body) {
					ok = false
					break
				}
				off += 4 // enterprise number — skipped
			}
			t.fields = append(t.fields, f)
		}
		if !ok {
			return
		}
		templates.Lock()
		if templates.m[scope] == nil {
			templates.m[scope] = map[uint16]template{}
		}
		templates.m[scope][id] = t
		templates.Unlock()
	}
}

func parseDataSet(agg *aggregator, exporter, scope string, setID uint16, body []byte) {
	templates.Lock()
	t, ok := templates.m[scope][setID]
	templates.Unlock()
	if !ok {
		return
	}
	recLen := 0
	for _, f := range t.fields {
		recLen += int(f.length)
	}
	if recLen == 0 {
		return
	}
	for off := 0; off+recLen <= len(body); off += recLen {
		var r flowRec
		var src6, dst6 []byte
		rec := body[off : off+recLen]
		p := 0
		for _, f := range t.fields {
			v := rec[p : p+int(f.length)]
			switch f.typ {
			case fInBytes:
				r.bytes = beUint(v)
			case fInPkts:
				r.packets = beUint(v)
			case fProtocol:
				r.proto = uint8(beUint(v))
			case fTcpFlags:
				r.tcpFlags = uint8(beUint(v))
			case fSrcPort:
				r.srcPort = uint16(beUint(v))
			case fDstPort:
				r.dstPort = uint16(beUint(v))
			case fSrcIPv4:
				if len(v) == 4 {
					r.srcIP = ipv4(v)
				}
			case fDstIPv4:
				if len(v) == 4 {
					r.dstIP = ipv4(v)
				}
			case fSrcIPv6:
				src6 = v
			case fDstIPv6:
				dst6 = v
			case fInputIf:
				r.inIf = uint32(beUint(v))
			case fOutputIf:
				r.outIf = uint32(beUint(v))
			}
			p += int(f.length)
		}
		if r.srcIP == "" && len(src6) == 16 {
			r.srcIP = net.IP(src6).String()
		}
		if r.dstIP == "" && len(dst6) == 16 {
			r.dstIP = net.IP(dst6).String()
		}
		if r.srcIP == "" || r.dstIP == "" {
			continue
		}
		agg.add(exporter, r)
	}
}

func beUint(b []byte) uint64 {
	var v uint64
	for _, x := range b {
		v = v<<8 | uint64(x)
	}
	return v
}
