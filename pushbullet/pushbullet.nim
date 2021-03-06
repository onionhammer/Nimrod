## Pushbullet API for Nim
when not defined(ssl):
    {.define: ssl.}

# Imports
import strutils, json, future, asyncdispatch, httpclient, strtabs

# Fields
const root_path   = "https://api.pushbullet.com/v2/"
var token: string = nil

# Types
type
    PushType* = enum
        Note, Link, Address, Checklist

    PushRequest* = object
        device*: string
        title*: string
        body*: string
        case kind*: PushType
        of PushType.Note: nil
        of PushType.Link:
            url*: string
        of PushType.Address:
            name*: string
            address*: string
        of PushType.Checklist:
            items*: seq[string]

# Procedures
proc `%`(kind: PushType): JsonNode =
    ## Convert a PushType kind to JSON node
    case kind:
    of PushType.Note:      %"note"
    of PushType.Link:      %"link"
    of PushType.Address:   %"address"
    of PushType.Checklist: %"checklist"

proc setToken*(value: string) =
    ## Set the API token
    token = value

proc getToken: string =
    ## Get the API token
    assert token != nil, "Token is currently empty"
    token

template `.`*(js: JsonNode, field: string): JsonNode =
    ## Automatically retrieve json node
    js[field]

converter jsonToStr*(js: JsonNode): string =
    ## Automatically convert json node to string
    js.str

proc getRequest(path: string): Future[JsonNode] {.async.} =
    ## GET request to pushbullet API
    let client = newAsyncHttpClient()
    client.headers["Authorization"] = "Bearer " & getToken()

    let response = await client.get(root_path & path)

    return parseJson(response.body)

proc postRequest(path: string, data: JsonNode): Future[JsonNode] {.async.} =
    ## POST request to pushbullet API
    let body   = $data
    let client = newAsyncHttpClient()
    client.headers["Authorization"]  = "Bearer " & getToken()
    client.headers["Content-Type"]   = "application/json"
    client.headers["Content-Length"] = $body.len

    let response = await client.request(
        root_path & path, httpPOST, body)

    return parseJson(response.body)

proc me*: Future[JsonNode] {.async.} =
    ## Get information about the current user.
    return await getRequest("users/me")

proc devices*: Future[JsonNode] {.async.} =
    ## List or create devices that can be pushed to.
    return (await getRequest("devices")).devices

proc contacts*: Future[JsonNode] {.async.} =
    ## List your Pushbullet contacts.
    return (await getRequest("contacts")).contacts

proc subscriptions*: Future[JsonNode] {.async.} =
    ## Channels that the user has subscribed to.
    return (await getRequest("subscriptions")).subscriptions

proc push*(args: PushRequest): Future[JsonNode] {.async, discardable.} =
    ## Push to a device/user or list existing pushes.
    var info = %[
        ( "type", %args.kind )]

    if args.device != nil:
        info.add("device_iden", %args.device)

    if args.title != nil and args.kind in [ PushType.Note, PushType.Link, PushType.Checklist ]:
        info.add("title", %args.title)

    case args.kind
    of PushType.Note:
        if args.body != nil:
            info.add("body", %args.body)
    of PushType.Link:
        if args.body != nil:
            info.add("body", %args.body)
        if args.url != nil:
            info.add("url", %args.url)
    of PushType.Address:
        if args.name != nil:
            info.add("name", %args.name)
        if args.address != nil:
            info.add("address", %args.address)
    of PushType.Checklist:
        if args.items != nil:
            info.add("items", %args.items.map((x: string) => %x))

    return await postRequest("pushes", info)


when isMainModule:
    ## App interface of library

    # Imports
    import os, parseopt2, uri

    # Fields
    const file_name = "token.cfg"
    let file_path   = joinPath(getAppDir(), file_name)

    # Procedures
    proc tryParseInt(value: string): int =
        try:    parseInt(value)
        except: -1

    proc tryParseUrl(value: string): string =
        if parseUri(value).scheme != "": value
        else: nil

    proc getStoredToken: string =
        var file: TFile
        result =
            if file.open(file_path): file.readLine()
            else: nil
        finally: file.close()

    proc setStoredToken =
        file_path.writeFile(token)

    proc main {.async.} =
        # Ensure we have API Token
        token = getStoredToken()

        while token == nil:
            # Request token from user
            stdout.write("API Token: ")
            setToken stdin.readLine()
            setStoredToken()

        # Parse command line
        var deviceIndex  = -1
        var note: string = nil
        var url: string  = nil

        for kind, key, value in getopt():
            case kind:
            of cmdArgument:
                if deviceIndex == -1:
                    # Parse as device index
                    deviceIndex = tryParseInt(key)
                    if deviceIndex >= 0: continue

                if url == nil:
                    # Parse as URL
                    url = tryParseUrl(key)
                    if url != nil: continue

                if note == nil:
                    # Treat as note
                    note = key
            else:
                # Do nothing
                discard

        var args = PushRequest(kind: PushType.Note)
        var allDevices: JsonNode

        if deviceIndex >= 0:
            # Retrieve device
            allDevices = await devices()
            if allDevices.len > deviceIndex:
                args.device = allDevices[deviceIndex].iden
            else:
                echo "Invalid device index"; return

        if url != nil:
            args.kind  = PushType.Link
            args.url   = url
            args.title = note
        elif note != nil:
            args.title = "Note"
            args.body  = note
        else:
            if allDevices == nil:
                allDevices = await devices()

            var i = 0
            echo "Devices:"
            for device in allDevices:
                echo "[$1] = $2" % [$i, device.nickname]
                inc i
            return

        # Transmit
        echo "Pushed to: ", (await push(args)).receiver_email

    waitFor main()