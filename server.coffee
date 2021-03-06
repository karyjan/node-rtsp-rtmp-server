# RTSP and RTMP/RTMPE/RTMPT/RTMPTE server implementation mainly for
# Raspberry Pi. Also serves HTTP contents as this server is meant to
# be run on port 80.

# TODO: clear old sessioncookies

net         = require 'net'
dgram       = require 'dgram'
fs          = require 'fs'
os          = require 'os'
crypto      = require 'crypto'
url         = require 'url'
path        = require 'path'
spawn       = require('child_process').spawn

codec_utils = require './codec_utils'
config      = require './config'
RTMPServer  = require './rtmp'
HTTPHandler = require './http'
rtp         = require './rtp'
sdp         = require './sdp'
h264        = require './h264'
aac         = require './aac'

# Clock rate for audio stream
audioClockRate = null

# Start playing from keyframe
ENABLE_START_PLAYING_FROM_KEYFRAME = false

# Maximum single NAL unit size
SINGLE_NAL_UNIT_MAX_SIZE = 1358

DAY_NAMES = [
  'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'
]

MONTH_NAMES = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
]

detectedVideoWidth = null
detectedVideoHeight = null
detectedAudioSampleRate = null
detectedAudioChannels = null
detectedAudioPeriodSize = null

# Delete UNIX domain sockets
deleteReceiverSocketsSync = ->
  if fs.existsSync config.videoReceiverPath
    try
      fs.unlinkSync config.videoReceiverPath
    catch e
      console.error "unlink error: #{e}"
  if fs.existsSync config.videoControlPath
    try
      fs.unlinkSync config.videoControlPath
    catch e
      console.error "unlink error: #{e}"
  if fs.existsSync config.audioReceiverPath
    try
      fs.unlinkSync config.audioReceiverPath
    catch e
      console.error "unlink error: #{e}"
  if fs.existsSync config.audioControlPath
    try
      fs.unlinkSync config.audioControlPath
    catch e
      console.error "unlink error: #{e}"

deleteReceiverSocketsSync()

# Create RTMP server
rtmpServer = new RTMPServer
rtmpServer.start ->
  # RTMP server is ready

httpHandler = new HTTPHandler

updateConfig = ->
  rtmpServer.updateConfig config

# profile-level-id is defined in RFC 6184.
# profile_idc, constraint flags for Baseline profile are
# defined in A.2.1 in H.264 Annex A.
# profile-level-id is a base16 representation of three bytes:
#   1) profile_idc (2 bytes) = 66 (Baseline profile)
#                              77 (Main profile)
#                              100 (High profile)
#   2) a byte herein referred to as profile-iop
#     (defined in 7.4.2.1.1 in H.264 spec)
#     constraint_set0_flag: 1 (Constrained Baseline Profile); Main=0
#     constraint_set1_flag: 1 (Constrained Baseline Profile); Main=1
#     constraint_set2_flag: 0; Main=0
#     constraint_set3_flag: Must be 0 (ignored by decoders in this case); Main=0
#     constraint_set4_flag: Must be 0 (ignored by decoders in this case); Main=0? (frame_mbs_only_flag)
#     constraint_set5_flag: Must be 0 (ignored by decoders in this case); Main=1 (B frames are not present)
#     reserved_zero_2bits : both 0
#   3) level_idc = 31 (Level 3.1)
PROFILE_LEVEL_ID = '42C01F'  # Baseline Profile, Level 3.1
# PROFILE_LEVEL_ID will be replaced with incoming SPS packet (NAL unit type 7), from byte 1 to 3

spropParameterSets = ''  # will be populated later
spsString = ''
ppsString = ''

# Update spropParameterSets based on NAL unit
updateSpropParam = (buf) ->
  nalUnitType = buf[0] & 0x1f
  if nalUnitType is 7  # SPS packet
    spsString = buf.toString 'base64'
    PROFILE_LEVEL_ID = buf[1..3].toString('hex').toUpperCase()
  else if nalUnitType is 8  # PPS packet
    ppsString = buf.toString 'base64'

  spropParameterSets = spsString + ',' + ppsString

clientsCount = 0
clients = {}
httpSessions = {}

zeropad = (columns, num) ->
  num += ''
  while num.length < columns
    num = '0' + num
  num

getDateHeader = ->
  d = new Date
  "#{DAY_NAMES[d.getUTCDay()]}, #{d.getUTCDate()} #{MONTH_NAMES[d.getUTCMonth()]}" +
  " #{d.getUTCFullYear()} #{zeropad 2, d.getUTCHours()}:#{zeropad 2, d.getUTCMinutes()}" +
  ":#{zeropad 2, d.getUTCSeconds()} UTC"

getLocalIP = ->
  ifaces = os.networkInterfaces()

  # wlan0, wlan1, ...
  for name, info of ifaces
    if /^wlan\d+$/.test name
      for addr in ifaces[name]
        if addr.family is 'IPv4'
          return addr.address

  # eth0, eth1, ...
  for name, info of ifaces
    if /^eth\d+$/.test name
      for addr in ifaces[name]
        if addr.family is 'IPv4'
          return addr.address

  # en0, en1, ...
  for name, info of ifaces
    if /^en\d+$/.test name
      for addr in ifaces[name]
        if addr.family is 'IPv4'
          return addr.address

  "127.0.0.1"

getExternalIP = ->
  "127.0.0.1" # TODO: Fetch this from UPnP or something

# Get local IP address which is meaningful to the
# partner of the given socket
getMeaningfulIPTo = (socket) ->
  if isPrivateNetwork socket
    return getLocalIP()
  else
    return getExternalIP()

timeForVideoRTPZero = null
timeForAudioRTPZero = null

getVideoRTPTimestamp = (time) ->
  return Math.round time * 90 % TIMESTAMP_ROUNDOFF

getAudioRTPTimestamp = (time) ->
  if not audioClockRate?
    throw new Error "audioClockRate is null"
  return Math.round time * (audioClockRate / 1000) % TIMESTAMP_ROUNDOFF

sendVideoSenderReport = (client) ->
  if not timeForVideoRTPZero?
    return

  time = new Date().getTime()
  buf = new Buffer rtp.createSenderReport
    time: time
    rtpTime: getVideoRTPTimestamp time - timeForVideoRTPZero
    ssrc: client.videoSSRC
    packetCount: client.videoPacketCount
    octetCount: client.videoOctetCount

  if client.useTCPForVideo
    if client.useHTTP
      if client.httpClientType is 'GET'
        sendDataByTCP client.socket, client.videoTCPControlChannel, buf
    else
      sendDataByTCP client.socket, client.videoTCPControlChannel, buf
  else
    videoRTCPSocket.send buf, 0, buf.length, client.clientVideoRTCPPort, client.ip, (err, bytes) ->
      if err
        console.error "[videoRTCPSend] error: #{err.message}"

sendAudioSenderReport = (client) ->
  if not timeForAudioRTPZero?
    return

  time = new Date().getTime()
  buf = new Buffer rtp.createSenderReport
    time: time
    rtpTime: getAudioRTPTimestamp time - timeForAudioRTPZero
    ssrc: client.audioSSRC
    packetCount: client.audioPacketCount
    octetCount: client.audioOctetCount

  if client.useTCPForAudio
    if client.useHTTP
      if client.httpClientType is 'GET'
        sendDataByTCP client.socket, client.audioTCPControlChannel, buf
    else
      sendDataByTCP client.socket, client.audioTCPControlChannel, buf
  else
    audioRTCPSocket.send buf, 0, buf.length, client.clientAudioRTCPPort, client.ip, (err, bytes) ->
      if err
        console.error "[audioRTCPSend] error: #{err.message}"

stopSendingRTCP = (client) ->
  if client.timeoutID?
    clearTimeout client.timeoutID
    client.timeoutID = null

# Send RTCP sender report packets for audio and video streams
sendSenderReports = (client) ->
  if not clients[client.socket.clientID]? # socket is already closed
    stopSendingRTCP client
    return

  sendAudioSenderReport client
  sendVideoSenderReport client

  client.timeoutID = setTimeout ->
    sendSenderReports client
  , config.rtcpSenderReportIntervalMs

startSendingRTCP = (client) ->
  stopSendingRTCP client

  sendSenderReports client

onReceiveVideoRTCP = (buf) ->
  # TODO: handle BYE message

onReceiveAudioRTCP = (buf) ->
  # TODO: handle BYE message

videoFrames = 0
audioFrames = 0
lastVideoStatsTime = null
lastAudioStatsTime = null

onReceiveVideoBuffer = (buf) ->
  # Using own format
  # pts (6 bytes)
  # NAL unit (remaining)
  pts = buf[0] * 0x010000000000 + \
        buf[1] * 0x0100000000   + \
        buf[2] * 0x01000000     + \
        buf[3] * 0x010000       + \
        buf[4] * 0x0100         + \
        buf[5]
  nalUnit = buf.slice 6
  onReceiveVideoPacket nalUnit, pts

onReceiveAudioBuffer = (buf) ->
  # Using own format
  # pts (6 bytes)
  # Access Unit == raw_data_block (remaining)
  pts = buf[0] * 0x010000000000 + \
        buf[1] * 0x0100000000   + \
        buf[2] * 0x01000000     + \
        buf[3] * 0x010000       + \
        buf[4] * 0x0100         + \
        buf[5]
  adtsFrame = buf.slice 6
  onReceiveAudioPacket adtsFrame, pts

videoReceiveServer = net.createServer (c) ->
  console.log "new videoReceiveServer connection"
  buf = null
  c.on 'close', ->
    console.log "videoReceiveServer connection closed"
  c.on 'data', (data) ->
    if config.debug.dropAllData
      return
    if buf?
      buf = Buffer.concat [buf, data], buf.length + data.length
    else
      buf = data
    if buf.length >= 3
      loop
        payloadSize = buf[0] * 0x10000 + buf[1] * 0x100 + buf[2]
        totalSize = payloadSize + 3  # 3 bytes for payload size
        if buf.length >= totalSize
          onReceiveVideoBuffer buf.slice 3, totalSize  # 3 bytes for payload size
          if buf.length > totalSize
            buf = buf.slice totalSize
          else
            buf = null
            break
        else
          break

videoReceiveServer.listen config.videoReceiverPath, ->
  fs.chmodSync config.videoReceiverPath, '777'

videoControlServer = net.createServer (c) ->
  console.log "new videoControl connection"
  c.on 'close', ->
    console.log "videoControl connection closed"
  c.on 'data', (data) ->
    if data[0] is 1  # timestamp information
      time  = data[1] * 0x0100000000000000  # this loses some precision
      time += data[2] * 0x01000000000000
      time += data[3] * 0x010000000000
      time += data[4] * 0x0100000000
      time += data[5] * 0x01000000
      time += data[6] * 0x010000
      time += data[7] * 0x0100
      time += data[8]
      lastVideoStatsTime = new Date().getTime()
      timeForVideoRTPZero = time / 1000
      timeForAudioRTPZero = timeForVideoRTPZero
      console.log "timeForVideoRTPZero: #{timeForVideoRTPZero}"
      spropParameterSets = ''
      rtmpServer.startStream timeForVideoRTPZero

videoControlServer.listen config.videoControlPath, ->
  fs.chmodSync config.videoControlPath, '777'

audioReceiveServer = net.createServer (c) ->
  console.log "new audioReceiveServer connection"
  buf = null
  c.on 'close', ->
    console.log "audioReceiveServer connection closed"
  c.on 'data', (data) ->
    if config.debug.dropAllData
      return
    if buf?
      buf = Buffer.concat [buf, data], buf.length + data.length
    else
      buf = data
    if buf.length >= 3
      loop
        payloadSize = buf[0] * 0x10000 + buf[1] * 0x100 + buf[2]
        totalSize = payloadSize + 3  # 3 bytes for payload size
        if buf.length >= totalSize
          onReceiveAudioBuffer buf.slice 3, totalSize  # 3 bytes for payload size
          if buf.length > totalSize
            buf = buf.slice totalSize
          else
            buf = null
            break
        else
          break

audioReceiveServer.listen config.audioReceiverPath, ->
  fs.chmodSync config.audioReceiverPath, '777'

audioControlServer = net.createServer (c) ->
  console.log "new audioControl connection"
  c.on 'close', ->
    console.log "audioControl connection closed"
  c.on 'data', (data) ->
    if data[0] is 1  # timestamp information
      time  = data[1] * 0x0100000000000000  # this loses some precision
      time += data[2] * 0x01000000000000
      time += data[3] * 0x010000000000
      time += data[4] * 0x0100000000
      time += data[5] * 0x01000000
      time += data[6] * 0x010000
      time += data[7] * 0x0100
      time += data[8]
      lastAudioStatsTime = new Date().getTime()
      timeForAudioRTPZero = time / 1000
      timeForVideoRTPZero = timeForAudioRTPZero
      console.log "timeForAudioRTPZero: #{timeForAudioRTPZero}"
      rtmpServer.startStream timeForAudioRTPZero

audioControlServer.listen config.audioControlPath, ->
  fs.chmodSync config.audioControlPath, '777'

# Generate random 32 bit unsigned integer.
# Return value is intended to be used as an SSRC identifier.
generateRandom32 = ->
  str = "#{new Date().getTime()}#{process.pid}#{os.hostname()}" + \
        "#{process.getuid()}#{process.getgid()}" + \
        (1 + Math.random() * 1000000000)

  md5sum = crypto.createHash 'md5'
  md5sum.update str
  md5sum.digest()[0..3].readUInt32BE(0)

# Generate new random session ID
# NOTE: Samsung SC-02B doesn't work with some hex string
generateNewSessionID = (callback) ->
  id = ''
  for i in [0..7]
    id += parseInt(Math.random() * 9) + 1
  callback null, id

highestClientID = 0

teardownClient = (id) ->
  client = clients[id]
  if client?
    console.log "[rtsp] teardownClient: id=#{id} session=#{client?.sessionID}"
    stopSendingRTCP client
    try
      client.socket.end()
    catch e
      console.error "socket.end() error: #{e}"
    delete clients[id]
    clientsCount--

listClients = ->
  console.log "#{Object.keys(clients).length} clients"
#  for clientID, client of clients
#    console.log " id=#{clientID} session=#{client.sessionID}"
  return

sendDataByTCP = (socket, channel, rtpBuffer) ->
  rtpLen = rtpBuffer.length
  tcpHeader = new Buffer [
    0x24, channel, rtpLen >> 8, rtpLen & 0xff,
  ]
  socket.write Buffer.concat [tcpHeader, rtpBuffer], 4 + rtpBuffer.length

handlePOSTData = (client, data) ->
  # Decode Base64-encoded data
  decodedRequest = new Buffer(data, 'base64').toString 'utf8'
  if decodedRequest[0] is 0x24  # dollar sign '$'
    console.log "[POST] Received an RTP packet (#{decodedRequest.length} bytes), ignored."
    for c in decodedRequest
      process.stdout.write c.toString(16) + ' '
    console.log()
    return
  req = parseRequest decodedRequest
  console.log "===request (decoded)==="
  process.stdout.write decodedRequest
  console.log "============="
  respond client.socket, req, (err, output) ->
    if err
      console.log "[respond] Error: #{err}"
      return
    console.log "===response==="
    process.stdout.write output
    console.log "============="
    client.getClient.socket.write output

clearTimeout = (socket) ->
  if socket.timeoutTimer?
    clearTimeout socket.timeoutTimer

scheduleTimeout = (socket) ->
  clearTimeout socket
  socket.scheduledTimeoutTime = Date.now() + config.keepaliveTimeoutMs
  socket.timeoutTimer = setTimeout ->
    if not clients[socket.clientID]?
      return
    if Date.now() < socket.scheduledTimeoutTime
      return
    console.log "keepalive timeout: #{socket.clientID}"
    teardownClient socket.clientID
  , config.keepaliveTimeoutMs

handleOnData = (c, data) ->
  id_str = c.clientID
  if not clients[id_str]?
    return

  if clients[id_str].isSendingPOST
    handlePOSTData clients[id_str], data.toString 'utf8'  # TODO: buffering
    return
  if c.buf?
    c.buf = Buffer.concat [c.buf, data], c.buf.length + data.length
  else
    c.buf = data
  if c.buf[0] is 0x24  # dollar sign '$'
    console.log "Received an RTP packet (#{c.buf.length} bytes), ignored."
    for b in c.buf
      process.stdout.write b.toString(16) + ' '
    console.log()
    c.buf = null
    return
  if c.ongoingRequest?
    req = c.ongoingRequest
    req.rawbody = Buffer.concat [req.rawbody, data], req.rawbody.length + data.length
    if req.rawbody.length < req.contentLength
      return
    req.socket = c
    bufString = req.rawbody.toString 'utf8'
    if req.rawbody.length > req.contentLength
      c.buf = req.rawbody[req.contentLength..]
      req.rawbody = req.rawbody[0...req.contentLength]
    else
      c.buf = null
  else
    bufString = c.buf.toString 'utf8'
    if bufString.indexOf('\r\n\r\n') is -1
      return
    req = parseRequest bufString
    req.rawbody = c.buf[req.headerBytes+4..]
    req.socket = c
    if req.headers['content-length']?
      req.contentLength = parseInt req.headers['content-length']
      if req.rawbody.length < req.contentLength
        c.ongoingRequest = req
        return
      if req.rawbody.length > req.contentLength
        c.buf = req.rawbody[req.contentLength..]
        req.rawbody = req.rawbody[0...req.contentLength]
      else
        c.buf = null
    else
      c.buf = req.rawbody
  c.ongoingRequest = null
  respond c, req, (err, output, resultOpts) ->
    if err
      console.error "[respond] Error: #{err}"
      return
    if output instanceof Array
      for out, i in output
        c.write out
    else
      c.write output
    if resultOpts?.close
      console.log "[#{c.clientID}] end"
      c.end()
    if c.buf?
      buf = c.buf
      c.buf = null
      handleOnData c, buf

onClientConnect = (c) ->
  # New client is connected
  highestClientID++
  id_str = 'c' + highestClientID
  console.log "client connected #{id_str}"
  generateNewSessionID (err, sessionID) ->
    throw err if err
    clients[id_str] =
      id: id_str
      sessionID: sessionID
      socket: c
      ip: c.remoteAddress
      isGlobal: not isPrivateNetwork c
      videoPacketCount: 0
      videoOctetCount: 0
      audioPacketCount: 0
      audioOctetCount: 0
      isPlaying: false
      timeoutID: null
      videoSSRC: generateRandom32()
      audioSSRC: generateRandom32()
      supportsReliableRTP: false
    clientsCount++
    listClients()
    c.setKeepAlive true, 120000
    c.clientID = id_str  # TODO: Is this safe?
    c.isAuthenticated = false
    c.requestCount = 0
    c.responseCount = 0
    c.on 'close', ->
      console.log "[#{new Date}] client #{id_str} is closed"
      teardownClient c.clientID
      listClients()
    c.buf = null
    c.on 'error', (err) ->
      console.error "Socket error (#{c.clientID}): #{err}"
      c.destroy()
    c.on 'data', (data) ->
      handleOnData c, data

process.on 'SIGINT', ->
  deleteReceiverSocketsSync()
  process.kill process.pid, 'SIGTERM'

process.on 'uncaughtException', (err) ->
  deleteReceiverSocketsSync()
  throw err

server = net.createServer (c) ->
  onClientConnect c

server.on 'error', (err) ->
  console.error "Server error: #{err.message}"
  throw err

console.log "Starting server on port #{config.serverPort}"
server.listen config.serverPort, '0.0.0.0', 511, ->
  console.log "Server is started"

videoSequenceNumber = 0
audioSequenceNumber = 0
TIMESTAMP_ROUNDOFF = 4294967296  # 32 bits

lastVideoRTPTimestamp = null
lastAudioRTPTimestamp = null
videoRTPTimestampInterval = Math.round(90000 / config.videoFrameRate)
audioRTPTimestampInterval = config.audioPeriodSize

getNextVideoSequenceNumber = ->
  num = videoSequenceNumber + 1
  if num > 65535
    num -= 65535
  num

getNextAudioSequenceNumber = ->
  num = audioSequenceNumber + 1
  if num > 65535
    num -= 65535
  num

getNextVideoRTPTimestamp = ->
  if lastVideoRTPTimestamp?
    lastVideoRTPTimestamp + videoRTPTimestampInterval
  else
    0

getNextAudioRTPTimestamp = ->
  if lastAudioRTPTimestamp?
    lastAudioRTPTimestamp + audioRTPTimestampInterval
  else
    0

videoRTPSocket = dgram.createSocket 'udp4'
videoRTPSocket.bind config.videoRTPServerPort
videoRTCPSocket = dgram.createSocket 'udp4'
videoRTCPSocket.bind config.videoRTCPServerPort

audioRTPSocket = dgram.createSocket 'udp4'
audioRTPSocket.bind config.audioRTPServerPort
audioRTCPSocket = dgram.createSocket 'udp4'
audioRTCPSocket.bind config.audioRTCPServerPort

sendVideoPacketWithFragment = (nalUnit, timestamp) ->
  ts = timestamp % TIMESTAMP_ROUNDOFF
  lastVideoRTPTimestamp = ts

  nalUnitType = nalUnit[0] & 0x1f
  if nalUnitType in [7, 8] # sprop
    updateSpropParam nalUnit

  if clientsCount is 0
    return

  isKeyFrame = nalUnitType is 5
  nal_ref_idc = nalUnit[0] & 0b01100000  # skip ">> 5" operation

  nalUnit = nalUnit.slice 1

  fragmentNumber = 0
  while nalUnit.length > SINGLE_NAL_UNIT_MAX_SIZE
    if ++videoSequenceNumber > 65535
      videoSequenceNumber -= 65535

    fragmentNumber++
    thisNalUnit = nalUnit.slice 0, SINGLE_NAL_UNIT_MAX_SIZE
    nalUnit = nalUnit.slice SINGLE_NAL_UNIT_MAX_SIZE

    # TODO: sequence number should be started from a random number
    rtpData = rtp.createRTPHeader
      marker: false
      payloadType: 97
      sequenceNumber: videoSequenceNumber
      timestamp: ts
      ssrc: null

    rtpData = rtpData.concat rtp.createFragmentationUnitHeader
      nal_ref_idc: nal_ref_idc
      nal_unit_type: nalUnitType
      isStart: fragmentNumber is 1
      isEnd: false

    # Append NAL unit
    thisNalUnitLen = thisNalUnit.length
    rtpBuffer = Buffer.concat [new Buffer(rtpData), thisNalUnit],
      rtp.RTP_HEADER_LEN + 2 + thisNalUnitLen

    for clientID, client of clients
      if client.isWaitingForKeyFrame and isKeyFrame
        process.stdout.write "KeyFrame"
        client.isPlaying = true
        client.isWaitingForKeyFrame = false

      if client.isPlaying
        rtp.replaceSSRCInRTP rtpBuffer, client.videoSSRC

        client.videoPacketCount++
        client.videoOctetCount += thisNalUnitLen
        if client.useTCPForVideo
          if client.useHTTP
            if client.httpClientType is 'GET'
              sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
          else
            sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
        else
          videoRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientVideoRTPPort, client.ip, (err, bytes) ->
            if err
              console.log "[videoRTPSend] error: #{err.message}"

  # last packet
  if ++videoSequenceNumber > 65535
    videoSequenceNumber -= 65535

  # TODO: sequence number should be started from a random number
  rtpData = rtp.createRTPHeader
    marker: true
    payloadType: 97
    sequenceNumber: videoSequenceNumber
    timestamp: ts
    ssrc: null

  rtpData = rtpData.concat rtp.createFragmentationUnitHeader
    nal_ref_idc: nal_ref_idc
    nal_unit_type: nalUnitType
    isStart: false
    isEnd: true

  nalUnitLen = nalUnit.length
  rtpBuffer = Buffer.concat [new Buffer(rtpData), nalUnit],
    rtp.RTP_HEADER_LEN + 2 + nalUnitLen
  for clientID, client of clients
    if client.isWaitingForKeyFrame and isKeyFrame
      process.stdout.write "KeyFrame"
      client.isPlaying = true
      client.isWaitingForKeyFrame = false

    if client.isPlaying
      rtp.replaceSSRCInRTP rtpBuffer, client.videoSSRC

      client.videoPacketCount++
      client.videoOctetCount += nalUnitLen
      if client.useTCPForVideo
        if client.useHTTP
          if client.httpClientType is 'GET'
            sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
        else
          sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
      else
        videoRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientVideoRTPPort, client.ip, (err, bytes) ->
          if err
            console.log "[videoRTPSend] error: #{err.message}"
  return

sendVideoPacketAsSingleNALUnit = (nalUnit, timestamp) ->
  if ++videoSequenceNumber > 65535
    videoSequenceNumber -= 65535

  ts = timestamp % TIMESTAMP_ROUNDOFF
  lastVideoRTPTimestamp = ts

  nalUnitType = nalUnit[0] & 0x1f
  if nalUnitType in [7, 8] # sprop
    updateSpropParam nalUnit

  if clientsCount is 0
    return

  isKeyFrame = nalUnitType is 5

  # TODO: sequence number should be started from a random number
  rtpHeader = rtp.createRTPHeader
    marker: true
    payloadType: 97
    sequenceNumber: videoSequenceNumber
    timestamp: ts
    ssrc: null

  nalUnitLen = nalUnit.length
  rtpBuffer = Buffer.concat [new Buffer(rtpHeader), nalUnit],
    rtp.RTP_HEADER_LEN + nalUnitLen
  for clientID, client of clients
    if client.isWaitingForKeyFrame and isKeyFrame
      process.stdout.write "KeyFrame"
      client.isPlaying = true
      client.isWaitingForKeyFrame = false

    if client.isPlaying
      rtp.replaceSSRCInRTP rtpBuffer, client.videoSSRC

      client.videoPacketCount++
      client.videoOctetCount += nalUnitLen
      if client.useTCPForVideo
        if client.useHTTP
          if client.httpClientType is 'GET'
            sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
        else
          sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
      else
        videoRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientVideoRTPPort, client.ip, (err, bytes) ->
          if err
            console.error "[videoRTPSend] error: #{err.message}"
  return

# Takes one H.264 NAL unit as argument
#
# arguments:
#   nalUnit: Buffer
#   timestamp: timestamp in 90 kHz clock rate (PTS)
onReceiveVideoPacket = (nalUnit, timestamp) ->
  nalUnitType = h264.getNALUnitType nalUnit
  if nalUnitType is h264.NAL_UNIT_TYPE_SPS
    h264.readSPS nalUnit
    sps = h264.getSPS()
    frameSize = h264.getFrameSize sps
    isConfigUpdated = false
    if detectedVideoWidth isnt frameSize.width
      detectedVideoWidth = frameSize.width
      console.log "detected video width change: #{detectedVideoWidth}"
      config.videoWidth = detectedVideoWidth
      isConfigUpdated = true
    if detectedVideoHeight isnt frameSize.height
      detectedVideoHeight = frameSize.height
      console.log "detected video height change: #{detectedVideoHeight}"
      config.videoHeight = detectedVideoHeight
      isConfigUpdated = true
    if config.flv.avclevel isnt sps.level_idc
      config.flv.avclevel = sps.level_idc
      console.log "avclevel is changed to #{config.flv.avclevel}"
      isConfigUpdated = true
    if config.flv.avcprofile isnt sps.profile_idc
      config.flv.avcprofile = sps.profile_idc
      console.log "avcprofile is changed to #{config.flv.avcprofile}"
      isConfigUpdated = true
    if isConfigUpdated
      updateConfig()

  rtmpServer.sendVideoPacket nalUnit, timestamp

  if nalUnit.length >= SINGLE_NAL_UNIT_MAX_SIZE
    sendVideoPacketWithFragment nalUnit, timestamp
  else
    sendVideoPacketAsSingleNALUnit nalUnit, timestamp

  return

updateAudioSampleRate = (sampleRate) ->
  audioClockRate = sampleRate
  config.audioSampleRate = sampleRate

updateAudioChannels = (channels) ->
  config.audioChannels = channels

onReceiveAudioPacket = (adtsFrame, pts) ->
  if audioClockRate isnt 90000
    timestamp = pts * audioClockRate / 90000

  adtsInfo = aac.parseADTSFrame adtsFrame

  if detectedAudioSampleRate isnt adtsInfo.sampleRate
    detectedAudioSampleRate = adtsInfo.sampleRate
    console.log "detected audio sample rate change: #{detectedAudioSampleRate}"
    updateAudioSampleRate adtsInfo.sampleRate

  if detectedAudioChannels isnt adtsInfo.channels
    detectedAudioChannels = adtsInfo.channels
    console.log "detected audio channels change: #{detectedAudioChannels}"
    updateAudioChannels adtsInfo.channels

  if config.audioObjectType isnt adtsInfo.audioObjectType
    config.audioObjectType = adtsInfo.audioObjectType
    console.log "audio object type is changed to #{config.audioObjectType}"
    updateConfig()

  rawDataBlock = adtsFrame[7..]
  rtmpServer.sendAudioPacket rawDataBlock, pts

  if ++audioSequenceNumber > 65535
    audioSequenceNumber -= 65535

  ts = timestamp % TIMESTAMP_ROUNDOFF
  lastAudioRTPTimestamp = ts

  if clientsCount is 0
    return

  rtpData = rtp.createRTPHeader
    marker: true
    payloadType: 96
    sequenceNumber: audioSequenceNumber
    timestamp: ts
    ssrc: null

  accessUnitLength = rawDataBlock.length

  # TODO: maximum size of AAC-hbr is 8191 octets
  # TODO: sequence number should be started from a random number

  rtpData = rtpData.concat rtp.createAudioHeader
    accessUnitLength: accessUnitLength

  # Append the access unit (rawDataBlock)
  rtpBuffer = Buffer.concat [new Buffer(rtpData), rawDataBlock],
    rtp.RTP_HEADER_LEN + 4 + accessUnitLength

  for clientID, client of clients
    if client.isPlaying
      rtp.replaceSSRCInRTP rtpBuffer, client.audioSSRC

      client.audioPacketCount++
      client.audioOctetCount += accessUnitLength
      if client.useTCPForAudio
        if client.useHTTP
          if client.httpClientType is 'GET'
            sendDataByTCP client.socket, client.audioTCPDataChannel, rtpBuffer
        else
          sendDataByTCP client.socket, client.audioTCPDataChannel, rtpBuffer
      else
        audioRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientAudioRTPPort, client.ip, (err, bytes) ->
          if err
            console.error "[audioRTPSend] error: #{err.message}"
  return

pad = (digits, n) ->
  n = n + ''
  while n.length < digits
    n = '0' + n
  n

getISO8601DateString = ->
  d = new Date
  str = "#{d.getUTCFullYear()}-#{pad 2, d.getUTCMonth()+1}-#{pad 2, d.getUTCDate()}T" + \
        "#{pad 2, d.getUTCHours()}:#{pad 2, d.getUTCMinutes()}:#{pad 2, d.getUTCSeconds()}." + \
        "#{pad 4, d.getUTCMilliseconds()}Z"
  str

consumePathname = (uri, callback) ->
  pathname = url.parse(uri).pathname[1..]

  # TODO: Implement authentication yourself
  authSuccess = true

  if authSuccess
    callback null
  else
    callback new Error 'Invalid access'

respondWithUnsupportedTransport = (callback, headers) ->
  res = 'RTSP/1.0 461 Unsupported Transport\n'
  if headers?
    for name, value of headers
      res += "#{name}: #{value}\n"
  res += '\n'
  callback null, res.replace /\n/g, '\r\n'

notFound = (protocol, opts, callback) ->
  res = """
  #{protocol}/1.0 404 Not Found
  Content-Length: 9
  Content-Type: text/plain

  """
  if opts?.keepalive
    res += "Connection: keep-alive\n"
  else
    res += "Connection: close\n"
  res += """

  Not Found
  """
  callback null, res.replace /\n/g, "\r\n"

respondWithNotFound = (protocol='RTSP', callback) ->
  res = """
  #{protocol}/1.0 404 Not Found
  Content-Length: 9
  Content-Type: text/plain

  Not Found
  """.replace /\n/g, "\r\n"
  callback null, res

# Check if the remote address of the given socket is private
isPrivateNetwork = (socket) ->
  if /^(10\.|192\.168\.|127\.0\.0\.)/.test socket.remoteAddress
    return true
  if (match = /^172.(\d+)\./.exec socket.remoteAddress)?
    num = parseInt match[1]
    if 16 <= num <= 31
      return true
  return false

respond = (socket, req, callback) ->
  client = clients[socket.clientID]
  if req.method is 'OPTIONS'
    res = """
    RTSP/1.0 200 OK
    CSeq: #{req.headers.cseq}
    Public: DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE


    """.replace /\n/g, "\r\n"
    callback null, res
  else if req.method is 'POST' and req.protocol.indexOf('HTTP') isnt -1
    pathname = url.parse(req.uri).pathname
    if config.enableRTMPT and /^\/(?:fcs|open|idle|send|close)\//.test pathname
      rtmpServer.handleRTMPTRequest req, (err, output, resultOpts) ->
        if err
          console.error "[rtmpt] Error: #{err}"
          respondWithNotFound 'HTTP', (err, response) ->
            callback response, resultOpts
        else
          callback err, output, resultOpts
      return
    # TODO: POST/GET connections may be re-initialized
    # Incoming channel
    if not httpSessions[req.headers['x-sessioncookie']]?
      respondWithNotFound 'HTTP', callback
      return
    socket.isAuthenticated = true
    client.sessionCookie = req.headers['x-sessioncookie']
    httpSessions[client.sessionCookie].post = client
    getClient = httpSessions[client.sessionCookie].get
    # Make circular reference
    getClient.postClient = client
    client.getClient = getClient
    client.useHTTP = true
    client.httpClientType = 'POST'
    client.isSendingPOST = true

    if req.body?
      handlePOSTData client, req.body
    # There's no response
  else if (req.method is 'GET') and (req.protocol.indexOf('HTTP') isnt -1)  # GET and HTTP
    pathname = url.parse(req.uri).pathname
    if pathname is '/crossdomain.xml'
      httpHandler.respondCrossDomainXML req, (err, output) ->
        callback err, output,
          close: req.headers.connection?.toLowerCase() isnt 'keep-alive'
      return
    else if (match = /^\/live\/(.*)$/.exec req.uri)?
      # Outgoing channel
      consumePathname req.uri, (err) ->
        if err
          console.warn "Can't consume pathname"
          respondWithNotFound 'HTTP', callback
          return
        client.sessionCookie = req.headers['x-sessioncookie']
        client.useHTTP = true
        client.httpClientType = 'GET'
        if httpSessions[client.sessionCookie]?
          postClient = httpSessions[client.sessionCookie].post
          if postClient?
            postClient.getClient = client
            client.postClient = postClient
        else
          httpSessions[client.sessionCookie] = {}
        httpSessions[client.sessionCookie].get = client
        socket.isAuthenticated = true
        res = """
        HTTP/1.0 200 OK
        Server: #{config.serverName}
        Connection: close
        Date: #{getDateHeader()}
        Cache-Control: no-store
        Pragma: no-cache
        Content-Type: application/x-rtsp-tunnelled


        """.replace /\n/g, "\r\n"

        callback null, res
    else
      httpHandler.handlePath pathname, req, (err, output) ->
        callback err, output,
          close: req.headers.connection?.toLowerCase() isnt 'keep-alive'
      return

#      console.warn "Routing failed: #{req.uri}"
#      isKeepAlive = req.headers.connection?.toLowerCase() is 'keep-alive'
#      opts = { keepalive: isKeepAlive }
#      notFound 'HTTP', opts, (err, content) ->
#        callback null, content,
#          close: not isKeepAlive
#      return

  else if req.method is 'DESCRIBE'  # DESCRIBE for RTSP, GET for HTTP
    consumePathname req.uri, (err) ->
      if err
        respondWithNotFound 'RTSP', callback
        return
      socket.isAuthenticated = true
      client.bandwidth = req.headers.bandwidth

      body = sdp.createSDP
        username: '-'
        sessionID: client.sessionID
        sessionVersion: client.sessionID
        addressType: 'IP4'
        unicastAddress: getMeaningfulIPTo socket
        audioPayloadType: 96
        audioEncodingName: 'mpeg4-generic'
        audioClockRate: audioClockRate
        audioChannels: config.audioChannels
        audioSampleRate: config.audioSampleRate
        audioObjectType: config.audioObjectType
        videoPayloadType: 97
        videoEncodingName: 'H264'  # must be H264
        videoClockRate: 90000  # must be 90000
        videoProfileLevelId: PROFILE_LEVEL_ID
        videoSpropParameterSets: spropParameterSets
        videoHeight: config.videoHeight
        videoWidth: config.videoWidth
        videoFrameRate: config.videoFrameRate.toFixed 1

      if /^HTTP\//.test req.protocol
        res = 'HTTP/1.0 200 OK\n'
      else
        res = 'RTSP/1.0 200 OK\n'
      if req.headers.cseq?
        res += "CSeq: #{req.headers.cseq}\n"
      dateHeader = getDateHeader()
      res += """
      Content-Base: #{req.uri}/
      Content-Length: #{body.length}
      Content-Type: application/sdp
      Date: #{dateHeader}
      Expires: #{dateHeader}
      Session: #{client.sessionID};timeout=60
      Server: #{config.serverName}
      Cache-Control: no-cache


      """.replace /\n/g, "\r\n"

      callback null, res + body
  else if req.method is 'SETUP'
    if not socket.isAuthenticated
      respondWithNotFound 'RTSP', callback
      return
    serverPort = null
    track = null

    # Check tranpsort
    # Disable UDP transport over the internet
#    if client.isGlobal and not /\bTCP\b/.test req.headers.transport
#      console.log "Unsupported transport: UDP is temporarily disabled"
#      respondWithUnsupportedTransport callback, {CSeq: req.headers.cseq}
#      return

    if /trackID=1/.test req.uri  # audio
      track = 'audio'
      if client.useHTTP
        ssrc = client.getClient.audioSSRC
      else
        ssrc = client.audioSSRC
      serverPort = "#{config.audioRTPServerPort}-#{config.audioRTCPServerPort}"
      if (match = /client_port=(\d+)-(\d+)/.exec req.headers.transport)?
        client.clientAudioRTPPort = parseInt match[1]
        client.clientAudioRTCPPort = parseInt match[2]
    else  # video
      track = 'video'
      if client.useHTTP
        ssrc = client.getClient.videoSSRC
      else
        ssrc = client.videoSSRC
      serverPort = "#{config.videoRTPServerPort}-#{config.videoRTCPServerPort}"
      if (match = /client_port=(\d+)-(\d+)/.exec req.headers.transport)?
        client.clientVideoRTPPort = parseInt match[1]
        client.clientVideoRTCPPort = parseInt match[2]

    if /\bTCP\b/.test req.headers.transport
      useTCPTransport = true
      if (match = /interleaved=(\d+)-(\d+)/.exec req.headers.transport)?
        ch1 = parseInt match[1]
        ch2 = parseInt match[2]
        # even channel number is used for data, odd number is for control
        if ch1 % 2 is 0
          [data_ch, control_ch] = [ch1, ch2]
        else
          [data_ch, control_ch] = [ch2, ch1]
      else
        if track is 'audio'
          data_ch = 0
          control_ch = 1
        else
          data_ch = 2
          control_ch = 3
      if track is 'video'
        if client.useHTTP
          target = client.getClient
        else
          target = client
        target.videoTCPDataChannel = data_ch
        target.videoTCPControlChannel = control_ch
        target.useTCPForVideo = true
      else
        if client.useHTTP
          target = client.getClient
        else
          target = client
        target.audioTCPDataChannel = data_ch
        target.audioTCPControlChannel = control_ch
        target.useTCPForAudio = true
    else
      useTCPTransport = false
      if track is 'video'
        client.useTCPForVideo = false
      else
        client.useTCPForAudio = false

    client.supportsReliableRTP = req.headers['x-retransmit'] is 'our-retransmit'
    if req.headers['x-dynamic-rate']?
      client.supportsDynamicRate = req.headers['x-dynamic-rate'] is '1'
    else
      client.supportsDynamicRate = client.supportsReliableRTP
    if req.headers['x-transport-options']?
      match = /late-tolerance=([0-9.]+)/.exec req.headers['x-transport-options']
      if match?
        client.lateTolerance = parseFloat match[1]

    if useTCPTransport
      if /interleaved=/.test req.headers.transport
        transportHeader = req.headers.transport
      else  # Maybe HTTP tunnelling
        transportHeader = req.headers.transport + ";interleaved=#{data_ch}-#{control_ch}" +
                          ";ssrc=#{zeropad(8, ssrc.toString(16))}"
    else
      transportHeader = req.headers.transport +
                        ";source=#{getMeaningfulIPTo socket}" +
                        ";server_port=#{serverPort};ssrc=#{zeropad(8, ssrc.toString(16))}"
    dateHeader = getDateHeader()
    res = """
    RTSP/1.0 200 OK
    Date: #{dateHeader}
    Expires: #{dateHeader}
    Transport: #{transportHeader}
    Session: #{client.sessionID};timeout=60
    CSeq: #{req.headers.cseq}
    Server: #{config.serverName}
    Cache-Control: no-cache


    """.replace /\n/g, "\r\n"
    callback null, res
    # after the response, client will send one or two RTP packets to this server
  else if req.method is 'PLAY'
    if not socket.isAuthenticated
      respondWithNotFound 'RTSP', callback
      return

    preventFromPlaying = false
#    if (req.headers['user-agent']?.indexOf('QuickTime') > -1) and
#    not client.getClient?.useTCPForVideo
#      # QuickTime produces poor quality image over UDP.
#      # So we let QuickTime switch transport.
#      console.log "[[[ UDP is discouraged for QuickTime ]]]"
#      preventFromPlaying = true

#    Range: clock=#{getISO8601DateString()}-
    # RTP-Info is defined in Section 12.33 in RFC 2326
    # seq: Indicates the sequence number of the first packet of the stream.
    # rtptime: Indicates the RTP timestamp corresponding to the time value in
    #          the Range response header.
    # TODO: Send this response after the first packet for this stream arrives
    baseUrl = req.uri.replace /\/$/, ''
    res = """
    RTSP/1.0 200 OK
    Range: npt=0.0-
    Session: #{client.sessionID};timeout=60
    CSeq: #{req.headers.cseq}
    RTP-Info: url=#{baseUrl}/trackID=1;seq=#{getNextAudioSequenceNumber()};rtptime=#{getNextAudioRTPTimestamp()},url=#{baseUrl}/trackID=2;seq=#{getNextVideoSequenceNumber()};rtptime=#{getNextVideoRTPTimestamp()}
    Server: #{config.serverName}
    Cache-Control: no-cache


    """.replace /\n/g, "\r\n"
    if not preventFromPlaying
      if client.useHTTP
        console.log "[[[ start sending to #{client.getClient.id} through GET ]]]"
        if ENABLE_START_PLAYING_FROM_KEYFRAME
          client.getClient.isWaitingForKeyFrame = true
        else
          client.getClient.isPlaying = true
      else if client.useTCPForVideo  # or client.useTCPForAudio?
        console.log "[[[ start sending to #{client.id} by TCP ]]]"
        if ENABLE_START_PLAYING_FROM_KEYFRAME
          client.isWaitingForKeyFrame = true
        else
          client.isPlaying = true
      else
        console.log "[[[ start sending to #{client.id} by UDP ]]]"
        if ENABLE_START_PLAYING_FROM_KEYFRAME
          client.isWaitingForKeyFrame = true
        else
          client.isPlaying = true
      if client.useHTTP
        startSendingRTCP client.getClient
      else
        startSendingRTCP client
    else
      console.log "[[[ NOT PLAYING ]]]"
    callback null, res
  else if req.method is 'PAUSE'
    if not socket.isAuthenticated
      respondWithNotFound 'RTSP', callback
      return
    stopSendingRTCP client
    if client.useHTTP
      client.getClient.isWaitingForKeyFrame = false
      client.getClient.isPlaying = false
    else
      client.isWaitingForKeyFrame = false
      client.isPlaying = false
    res = """
    RTSP/1.0 200 OK
    Session: #{client.sessionID};timeout=60
    CSeq: #{req.headers.cseq}
    Cache-Control: no-cache


    """.replace /\n/g, "\r\n"
    callback null, res
  else if req.method is 'TEARDOWN'
    if not socket.isAuthenticated
      respondWithNotFound 'RTSP', callback
      return
    if client.useHTTP
      client.getClient.isWaitingForKeyFrame = false
      client.getClient.isPlaying = false
    else
      client.isWaitingForKeyFrame = false
      client.isPlaying = false
    res = """
    RTSP/1.0 200 OK
    Session: #{client.sessionID};timeout=60
    CSeq: #{req.headers.cseq}
    Cache-Control: no-cache


    """.replace /\n/g, "\r\n"
    callback null, res
  else
    console.warn "method not implemented: #{req.method}"
    respondWithNotFound 'RTSP', callback

parseRequest = (data) ->
  [headerPart, body] = data.split '\r\n\r\n'

  lines = headerPart.split /\r\n/
  [method, uri, protocol] = lines[0].split /\s+/
  headers = {}
  for line, i in lines
    continue if i is 0
    continue if /^\s*$/.test line
    params = line.split ": "
    headers[params[0].toLowerCase()] = params[1]
  method: method
  uri: decodeURIComponent uri
  protocol: protocol
  headers: headers
  body: body
  headerBytes: headerPart.length  # TODO
