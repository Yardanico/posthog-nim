import std / [
  sequtils,
  times,
  strformat, json, oids,
  httpclient, asyncdispatch,
  macros
]

type
  PosthogEventKind = enum
    Identify = "identify",
    Capture = "capture"

  PosthogClientBase[HttpBase] = ref object
    apiUrl: string
    apiKey: string
    distinctId: string

  PosthogClient = PosthogClientBase[HttpClient]
  AsyncPosthogClient = PosthogClientBase[AsyncHttpClient]

const
  PosthogCaptureUrl* = "https://app.posthog.com/capture/"
  PosthogLib = "posthog-nim"
  PosthogLibVersion = "0.0.1"

proc newPosthogClient*(url = PosthogCaptureUrl, apiKey: string, distinctId = ""): PosthogClient =
  result = PosthogClient(
    apiUrl: url,
    apiKey: apiKey,
    distinctId: if distinctId == "": $genOid() else: distinctId
  )

proc newAsyncPosthogClient*(url = PosthogCaptureUrl, apiKey: string, distinctId = ""): AsyncPosthogClient =
  result = AsyncPosthogClient(
    apiUrl: url,
    apiKey: apiKey,
    distinctId: if distinctId == "": $genOid() else: distinctId
  )

proc send(client: PosthogClient | AsyncPosthogClient, kind: PosthogEventKind,
    msg: JsonNode) {.multisync.} =
  msg["type"] = %kind
  if "event" notin msg:
    msg["event"] = %kind

  if "distinct_id" notin msg:
    msg["distinct_id"] = %client.distinctId

  if "timestamp" notin msg:
    msg["timestamp"] = % $now()

  msg["properties"]["$lib"] = %PosthogLib
  msg["properties"]["$lib_version"] = %PosthogLibVersion

  msg["api_key"] = %client.apiKey
  echo "sending msg - ", msg.pretty()

  let client = when client is PosthogClient:
    newHttpClient()
  else:
    newAsyncHttpClient()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})

  let resp = await client.post(PosthogCaptureUrl, $msg)
  echo "resp obj - ", resp[]
  echo "body - ", (await resp.body)

  client.close()

macro makeTableConstr(data: varargs[untyped]): untyped =
  let jsonMacro = bindSym"%*"
  var props = newNimNode(nnkTableConstr)
  var table = newNimNode(nnkTableConstr)
  let specials = ["event", "distinct_id", "timestamp"]
  for arg in data.children:
    # We only accepts arguments like "abcd=something"
    expectKind(arg, nnkExprEqExpr)
    let nameLit = arg[0].toStrLit
    # reserve some params for special handling - add it to the
    # parent table constructor instead of "properties"
    block foundSpecial:
      for i, special in specials:
        if special.eqIdent(arg[0]):
          # we create a newLit of special here because
          # we need to convert user-provided distinctId
          # to distinct_id or similar.
          table.add newColonExpr(newLit(special), arg[1])
          break foundSpecial
      props.add newColonExpr(nameLit, arg[1])

  # If we don't have any properties, set it to empty object
  # because it'll be used later in the send proc
  if props.len == 0:
    props = newCall bindSym"newJObject"

  table.add newColonExpr(newLit("properties"), props)

  result = quote do:
    `jsonMacro`(`table`)
  echo repr result
  echo treeRepr result

template identify*(client: PosthogClient, data: varargs[untyped]) =
  client.send(Identify, makeTableConstr(data))

template capture*(client: PosthogClient, data: varargs[untyped]) =
  client.send(Capture, makeTableConstr(data))