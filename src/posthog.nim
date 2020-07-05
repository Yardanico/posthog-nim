##[

Hello there! This is a relatively simple library for using Posthog 
open-source product analytics service. 

Right now there's not a lot of stuff implemented, 
but it is already useable. Just read the example below 
and you'll be able to use this brary :)

Create a new Posthog client with the specified api key
and ``distinctId`` being ``myuser`` to not specify it in every call.
```nim
let client = newPosthogClient(apiKey = "myApiKey", user = "myuser")
```
By default this uses the official PostHug SaaS instance, but 
you can override it by specifying the URL yourself:
```nim
let client = newPosthogClient(
  url = "https://myurl.com/capture", 
  apiKey = "myApiKey", 
  user = "myuser"
)
```

Identify the user - so that Posthog will remember them and you can also
attach some fields to the user:
```nim
client.identify(
  # specify event name for Posthog
  event = "logged in",
  email = "john@doe.com",
  proUser = false
)
```
Internally ``identify`` uses ``json``'s ``%*`` macro, so most types will 
be automatically supported. If you need to handle a type not supported 
by the ``%*`` macro  (but that's really rare), you will need to write 
a ``%`` proc for it

Capture some event:
```nim
client.capture(
  event = "logged out",
  reason = "AppExit"
)
```

Most calls like ``identify`` or ``capture`` in this library rely on a macro
to automatically transform all arguments to necessary JSON objects. The macro
also handles special cases like ``timestamp``, ``distinctId``, ``event`` or others,
so you shouldn't generally worry about the library overriding them 
(if you want to specify them manually).
]##

import std / [
  times,
  strformat, json, oids,
  httpclient, asyncdispatch,
  macros
]

type
  PosthogEventKind = enum
    Identify = "identify", 
    Capture = "capture"

  PosthogClientBase*[HttpBase] = ref object
    ## Base object for async/sync client instances
    apiUrl: string
    apiKey: string
    distinctId*: string ## You can override distinctId at any time

  PosthogClient* = PosthogClientBase[HttpClient] ## \
    ## Synchronous Posthog client instance
  AsyncPosthogClient* = PosthogClientBase[AsyncHttpClient] ## \
    ## Asynchronous Posthog client instance

const
  PosthogCaptureUrl* = "https://app.posthog.com/capture/" ## \
    ## URL for the official Posthog instance (SaaS on https://posthog.com/trial)
  PosthogLib = "posthog-nim"
  PosthogLibVersion = "0.0.1"

proc newPosthogClient*(url = PosthogCaptureUrl, apiKey: string, user = ""): PosthogClient =
  ## Creates a new PosthogClient with the instance URL from ``url``,
  ## ``apiKey`` for authorization and optionally ``user``
  ## (Posthog's ``distinctId``) to not set it for each call 
  ## (you can overwrite it at any time later or still specify it in calls)
  result = PosthogClient(
    apiUrl: url,
    apiKey: apiKey,
    distinctId: if user == "": $genOid() else: user
  )

proc newAsyncPosthogClient*(url = PosthogCaptureUrl, apiKey: string, user = ""): AsyncPosthogClient =
  result = AsyncPosthogClient(
    apiUrl: url,
    apiKey: apiKey,
    distinctId: if user == "": $genOid() else: user
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

template identify*(client: PosthogClient, data: varargs[untyped]) =
  ## Identify the current user (create or update user data in Posthog)
  ## with specified parameters, for example:
  ##
  ## ```nim
  ## client.identify(
  ##   email = "john@doe.com",
  ##   proUser = false,
  ##   distinctId = "test" # override the distinctId set in client
  ## )
  ## ```
  client.send(Identify, makeTableConstr(data))

template capture*(client: PosthogClient, data: varargs[untyped]) =
  ## Capture an event with some parameters, for example:
  ##
  ## ```nim
  ## client.capture(
  ##   event = "purchase",
  ##   moneySpent = 100,
  ##   paymentService = "paypal",
  ##   itemBought = "Ultimate Excalibur Sword"
  ## )
  ## ```
  client.send(Capture, makeTableConstr(data))