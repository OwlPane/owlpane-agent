"""A minimal Kubernetes API server (discovery + list for configmaps and pods) so the REAL k8s_objects receiver can be run
against objects that carry secrets. Used by scripts/test-object-scrub.sh."""
import json, http.server
CM = {"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"app-config","namespace":"prod","resourceVersion":"5","uid":"u1","creationTimestamp":"2026-09-01T00:00:00Z",
      "annotations":{"kubectl.kubernetes.io/last-applied-configuration":"{\"data\":{\"DB_PASSWORD\":\"hunter2\"}}","team":"payments"}},
      "data":{"DB_PASSWORD":"hunter2","settings.yaml":"token: abc123\nurl: https://x"},"binaryData":{"blob":"c2VjcmV0"}}
POD = {"apiVersion":"v1","kind":"Pod","metadata":{"name":"web-1","namespace":"prod","resourceVersion":"6","uid":"u2"},
       "spec":{"containers":[{"name":"web","image":"nginx:1.27","env":[{"name":"API_KEY","value":"sk-live-SECRET123"},{"name":"MODE","value":"prod"},{"name":"FROM_CM","valueFrom":{"configMapKeyRef":{"name":"app-config","key":"x"}}}]}],
       "tolerations":[{"key":"dedicated","operator":"Equal","value":"gpu","effect":"NoSchedule"}]}}
def res(name,kind,verbs=("get","list","watch")): return {"name":name,"singularName":"","namespaced":True,"kind":kind,"verbs":list(verbs)}
ROUTES = {
 "/api": {"kind":"APIVersions","versions":["v1"],"serverAddressByClientCIDRs":[]},
 "/apis": {"kind":"APIGroupList","apiVersion":"v1","groups":[]},
 "/api/v1": {"kind":"APIResourceList","groupVersion":"v1","resources":[res("configmaps","ConfigMap"),res("pods","Pod")]},
 "/api/v1/configmaps": {"kind":"ConfigMapList","apiVersion":"v1","metadata":{"resourceVersion":"7"},"items":[CM]},
 "/api/v1/pods": {"kind":"PodList","apiVersion":"v1","metadata":{"resourceVersion":"7"},"items":[POD]},
}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p=self.path.split('?')[0]
        body=ROUTES.get(p)
        if body is None: self.send_response(404); self.end_headers(); self.wfile.write(b'{}'); return
        d=json.dumps(body).encode(); self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(d))); self.end_headers(); self.wfile.write(d)
    def log_message(self,*a): pass
import sys
http.server.HTTPServer(('127.0.0.1',int(sys.argv[1]) if len(sys.argv)>1 else 8899),H).serve_forever()
