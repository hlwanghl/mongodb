cfg = db.system.replset.findOne( { '_id': mongoRsName } );
cfg.members.forEach(m => m.host = mongoRsHosts[m._id]);
db.system.replset.update( { "_id": mongoRsName } , cfg )
