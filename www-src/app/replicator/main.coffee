request = require '../lib/request'
fs = require './filesystem'
makeDesignDocs = require './replicator_mapreduce'
ReplicatorConfig = require './replicator_config'
DBNAME = "cozy-files.db"
DBCONTACTS = "cozy-contacts.db"
DBOPTIONS = if window.isBrowserDebugging then {} else adapter: 'websql'

#Replicator extends Model to watch/set inBackup, inSync
module.exports = class Replicator extends Backbone.Model

    db: null
    config: null

    # backup functions (contacts & images) are in replicator_backups
    _.extend Replicator.prototype, require './replicator_backups'

    defaults: ->
        inSync: false
        inBackup: false

    destroyDB: (callback) ->
        @db.destroy (err) =>
            return callback err if err
            @contactsDB.destroy (err) =>
                return callback err if err
                fs.rmrf @downloads, callback

    resetSynchro: (callback) ->
        console.log "resetSynchro"
        @set 'inSync', true
        @_sync true, (err) =>
            @set 'inSync', false
            callback err

    init: (callback) ->
        fs.initialize (err, downloads, cache) =>
            return callback err if err
            @downloads = downloads
            @cache = cache
            @db = new PouchDB DBNAME, DBOPTIONS
            @contactsDB = new PouchDB DBCONTACTS, DBOPTIONS
            makeDesignDocs @db, @contactsDB, (err) =>
                return callback err if err
                @config = new ReplicatorConfig(this)
                @config.fetch callback

    getDbFilesOfFolder: (folder, callback) ->
        path = folder.path + '/' + folder.name
        options =
            include_docs: true
            startkey: path
            endkey: path + '\uffff'

        @db.query 'FilesAndFolder', options, (err, results) ->
            return callback err if err
            docs = results.rows.map (row) -> row.doc
            files = docs.filter (doc) -> doc.docType?.toLowerCase() is 'file'
            callback null, files

    registerRemote: (config, callback) ->
        request.post
            uri: "https://#{config.cozyURL}/device/",
            auth:
                username: 'owner'
                password: config.password
            json:
                login: config.deviceName
                type: 'mobile'
        , (err, response, body) =>
            if err
                callback err
            else if response.statusCode is 401 and response.reason
                callback new Error('cozy need patch')
            else if response.statusCode is 401
                callback new Error('wrong password')
            else if response.statusCode is 400
                callback new Error('device name already exist')
            else
                _.extend config,
                    password: body.password
                    deviceId: body.id
                    auth:
                        username: config.deviceName
                        password: body.password
                    fullRemoteURL:
                        "https://#{config.deviceName}:#{body.password}" +
                        "@#{config.cozyURL}/cozy"

                @config.save config, callback

    # pings the cozy to check the credentials without creating a device
    checkCredentials: (config, callback) ->
        request.post
            uri: "https://#{config.cozyURL}/login"
            json:
                username: 'owner'
                password: config.password
        , (err, response, body) ->

            if response?.statusCode isnt 200
                error = err?.message or body.error or body.message
            else
                error = null

            callback error

    updateIndex: (callback) ->
        # build the search index
        @db.search
            build: true
            fields: ['name']
        , (err) =>
            console.log "INDEX BUILT"
            console.log err if err
            # build pouch's map indexes
            @db.query 'FilesAndFolder', {}, =>
                # build pouch's map indexes
                @db.query 'LocalPath', {}, ->
                    callback null

    initialReplication: (callback) ->
        @set 'initialReplicationRunning', 0
        async.series [
            # Force checkpoint to 0
            (cb) => @config.save checkpointed: 0, cb
            (cb) => @set('initialReplicationRunning', 1/10) and cb null
            # First sync
            (cb) => @_sync cb, true
            (cb) => @set('initialReplicationRunning', 9/10) and cb null
            # build the initial state of FilesAndFolder view index
            (cb) => @db.query 'FilesAndFolder', {}, cb
        ], (err) =>
            console.log "end of inital replication #{Date.now()}"
            @set 'initialReplicationRunning', 1
            callback err
            # updateIndex In background
            @updateIndex -> console.log "Index built"

    fileInFileSystem: (file) =>
        @cache.some (entry) -> entry.name is file.binary.file.id

    folderInFileSystem: (path, callback) =>
        options =
            startkey: path
            endkey: path + '\uffff'

        fsCacheFolder = @cache.map (entry) -> entry.name

        @db.query 'PathToBinary', options, (err, results) ->
            return callback err if err
            return callback null, null if results.rows.length is 0
            callback null, _.every results.rows, (row) ->
                row.value in fsCacheFolder

    getBinary: (model, progressback, callback) ->
        binary_id = model.binary.file.id

        fs.getOrCreateSubFolder @downloads, binary_id, (err, binfolder) =>
            return callback err if err and err.code isnt FileError.PATH_EXISTS_ERR
            unless model.name
                return callback new Error('no model name :' + JSON.stringify(model))

            fs.getFile binfolder, model.name, (err, entry) =>
                return callback null, entry.toURL() if entry

                # getFile failed, let's download
                options = @config.makeUrl "/#{binary_id}/file"
                options.path = binfolder.toURL() + '/' + model.name

                fs.download options, progressback, (err, entry) =>
                    if err
                        # failed to download
                        fs.delete binfolder, (delerr) ->
                            #@TODO handle delerr
                            callback err
                    else
                        @cache.push binfolder
                        callback null, entry.toURL()

    getBinaryFolder: (folder, progressback, callback) ->
        @getDbFilesOfFolder folder, (err, files) =>
            return callback err if err

            totalSize = files.reduce ((sum, file) -> sum + file.size), 0

            fs.freeSpace (err, available) =>
                return callback err if err
                if totalSize > available * 1024 # available is in KB
                    alert t 'not enough space'
                    callback null
                else

                    progressHandlers = {}
                    reportProgress = (id, done, total) ->
                        progressHandlers[id] = [done, total]
                        total = done = 0
                        for key, status of progressHandlers
                            done += status[0]
                            total += status[1]
                        progressback done, total


                    async.eachLimit files, 5, (file, cb) =>
                        console.log "DOWNLOAD #{file.name}"
                        pb = reportProgress.bind null, file._id
                        @getBinary file, pb, cb
                    , callback


    removeLocal: (model, callback) ->
        binary_id = model.binary.file.id
        console.log "REMOVE LOCAL"
        console.log binary_id

        fs.getDirectory @downloads, binary_id, (err, binfolder) =>
            return callback err if err
            fs.rmrf binfolder, (err) =>
                # remove from @cache
                for entry, index in @cache when entry.name is binary_id
                    @cache.splice index, 1
                    break
                callback null

    removeLocalFolder: (folder, callback) ->
         @getDbFilesOfFolder folder, (err, files) =>
            return callback err if err

            async.eachSeries files, (file, cb) =>
                @removeLocal file, cb
            , callback

    # wrapper around _sync to maintain the state of inSync
    sync: (callback) ->
        return callback null if @get 'inSync'
        console.log "SYNC CALLED"
        @set 'inSync', true
        @_sync (err) =>
            @set 'inSync', false
            callback err

    # One-shot replication
    # Called for :
    #    * first replication
    #    * replication at each start
    #    * replication force byu user
    _sync: (callback, force=false) ->
        console.log "BEGIN SYNC"
        total_count = 0
        @liveReplication?.cancel()
        if not force
            checkpoint = @config.get 'checkpointed'
        else
            checkpoint = 0
            # Recover number of couments in cozy to inform user
            # replication progression.
            options = @config.makeUrl "/_design/file/_view/all/"
            request.get options, (err, res, files) =>
                options = @config.makeUrl "/_design/folder/_view/all/"
                request.get options, (err, res, folders) =>
                    total_count = files.total_rows + folders.total_rows
                    console.log "TOTAL DOCUMENTS : #{total_count}"

        replication = @db.replicate.from @config.remote,
            batch_size: 5
            batches_limit: 1
            filter: (doc) ->
                doc.docType is 'Folder' or doc.docType is 'File'
            live: false
            since: checkpoint

        replication.on 'change', (change) =>
            if force
                @db.info (err, info) =>
                    console.log "LOCAL DOCUMENTS : #{info.doc_count - 4} / #{total_count}"
                    progress = 1 / 10 + (4 / 5) * ((info.doc_count - 4) / total_count)
                    @set('initialReplicationRunning', progress)

        replication.once 'error', (err) ->
            console.log "REPLICATOR ERRROR #{JSON.stringify(err)} #{err.stack}"

        replication.once 'complete', (result) =>
            console.log "REPLICATION COMPLETED"
            @config.save checkpointed: result.last_seq, (err) =>
                callback err
                app.router.forceRefresh()
                # updateIndex In background
                @updateIndex =>
                    console.log 'start Realtime'
                    @startRealtime()

    # realtime
    # start from the last checkpointed value
    # smaller batches to limit memory usage
    # if there is an error, we keep trying
    # with exponential backoff 2^x s (max 1min)
    #
    realtimeBackupCoef = 1
    startRealtime: =>
        return if @liveReplication
        console.log 'REALTIME START'
        @liveReplication = @db.replicate.from @config.remote,
            batch_size: 50
            batches_limit: 5
            filter: @config.makeFilterName()
            since: @config.get 'checkpointed'
            continuous: true

        @liveReplication.on 'change', (e) =>
            realtimeBackupCoef = 1
            @set 'inSync', true

        @liveReplication.on 'uptodate', (e) =>
            realtimeBackupCoef = 1
            app.router.forceRefresh()
            @set 'inSync', false
            # @TODO : save last_seq ?
            console.log "UPTODATE", e

        @liveReplication.once 'complete', (e) =>
            console.log "LIVE REPLICATION CANCELLED"
            @set 'inSync', false
            @liveReplication = null

        @liveReplication.once 'error', (e) =>
            @liveReplication = null
            realtimeBackupCoef++ if realtimeBackupCoef < 6
            timeout = 1000 * (1 << realtimeBackupCoef)
            console.log "REALTIME BROKE, TRY AGAIN IN #{timeout} #{e.toString()}"
            setTimeout @startRealtime, timeout