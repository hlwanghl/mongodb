ss = db.serverStatus();

fields = {
	connections: [ "current", "totalCreated", "available" ],
	globalLock: {
		activeClients: [ "writers", "readers", "total" ],
		currentQueue: [ "writers", "readers", "total" ]
	},
	network: [ "bytesIn", "bytesOut", "physicalBytesIn", "physicalBytesOut" ],
	opcounters: [ "insert", "query", "update", "delete" ],
	opcountersRepl: [ "insert", "query", "update", "delete" ],
	wiredTiger: {
		cache: [ "tracked dirty pages in the cache", "bytes currently in the cache", "maximum bytes configured", "bytes read into cache", "bytes written from cache" ],
		concurrentTransactions: {
			write: [ "out", "available" ],
			read: [ "out", "available" ]
		}
	}
};

var build = function(node, path = [], paths = []) {
  if(Array.isArray(node)) {
    node.forEach(leaf => paths.push(path.concat(leaf)));
  } else {
    Object.keys(node).forEach(k =>
      build(node[k], path.concat(k), paths)
    );
  }
  return paths;
};

var result = {};
build(fields).forEach(path => {
	var key = path.join("-").replace(/\s/g, "-");
	var obj = ss;
  path.forEach(f => obj = obj[f]);
  if(/bytes/i.test(key)) {
    obj = Math.round(obj / (1024 * 1024));
  }
	result[key] = obj;
});

result["cache-usage"] = Math.round(10000 * result["wiredTiger-cache-bytes-currently-in-the-cache"] / result["wiredTiger-cache-maximum-bytes-configured"]);
printjsononeline(result);
