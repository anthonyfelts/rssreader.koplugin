-- An in-memory Feedbin API v2, installed in place of socket.http/ssl.https.
-- It keeps unread and starred IDs as server state, so marking calls can be
-- checked by what the server ends up holding, and records every request.

local json = require("json")
local http = require("socket.http")
local https = require("ssl.https")
local mime = require("mime")

local FakeFeedbin = {}
FakeFeedbin.__index = FakeFeedbin

FakeFeedbin.EMAIL = "reader@example.com"
FakeFeedbin.PASSWORD = "secret"
FakeFeedbin.EXTRACT_HOST = "https://extract.feedbin.test"

local function setOf(list)
    local set = {}
    for _, v in ipairs(list or {}) do
        set[v] = true
    end
    return set
end

-- opts.subscriptions: { {feed_id, title} }, opts.taggings: { {feed_id, name} },
-- opts.entries: { {id, feed_id, title, ...} }, opts.unread / opts.starred: ID lists.
function FakeFeedbin.new(opts)
    opts = opts or {}
    local server = setmetatable({
        subscriptions = opts.subscriptions or {},
        taggings = opts.taggings or {},
        entries = opts.entries or {},
        unread = setOf(opts.unread),
        starred = setOf(opts.starred),
        extractions = opts.extractions or {},
        -- path -> raw response body, for what a Lua table cannot express
        -- (JSON null decodes to a sentinel in KOReader's LuaJSON, not nil).
        raw_responses = opts.raw_responses or {},
        -- true: answer every request with HTTP 500.
        failing = false,
        requests = {},
    }, FakeFeedbin)
    return server
end

-- A plausible entry; fields can be overridden.
function FakeFeedbin.entry(id, feed_id, fields)
    local entry = {
        id = id,
        feed_id = feed_id,
        title = "Entry " .. id,
        url = "https://example.com/" .. id,
        author = "Author " .. id,
        content = "<p>Content of entry " .. id .. "</p>",
        summary = "Summary " .. id,
        published = "2026-10-07T09:51:43.000000Z",
        created_at = "2026-10-07T10:00:00.000000Z",
        extracted_content_url = FakeFeedbin.EXTRACT_HOST .. "/parser/feedbin/sig" .. id,
    }
    for k, v in pairs(fields or {}) do
        entry[k] = v
    end
    return entry
end

function FakeFeedbin:install()
    self.saved_http = http.request
    self.saved_https = https.request
    local handler = function(options)
        return self:handle(options)
    end
    http.request = handler
    https.request = handler
    return self
end

function FakeFeedbin:uninstall()
    http.request = self.saved_http
    https.request = self.saved_https
end

function FakeFeedbin:requestsMatching(method, path_prefix)
    local found = {}
    for _, req in ipairs(self.requests) do
        if (not method or req.method == method) and req.path:sub(1, #path_prefix) == path_prefix then
            found[#found + 1] = req
        end
    end
    return found
end

function FakeFeedbin:clearRequests()
    self.requests = {}
end

function FakeFeedbin:unreadIds()
    local ids = {}
    for id in pairs(self.unread) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    return ids
end

local function parseQuery(query)
    local params = {}
    for pair in (query or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]+)=?(.*)$")
        if k then
            params[k] = v
        end
    end
    return params
end

local function readBody(source)
    if not source then
        return nil
    end
    local chunks = {}
    while true do
        local chunk = source()
        if not chunk then
            break
        end
        chunks[#chunks + 1] = chunk
    end
    return table.concat(chunks)
end

-- Entries newest first, like Feedbin (by created_at; IDs grow with it here).
function FakeFeedbin:sortedEntries(filter)
    local list = {}
    for _, entry in ipairs(self.entries) do
        if not filter or filter(entry) then
            list[#list + 1] = entry
        end
    end
    table.sort(list, function(a, b) return a.id > b.id end)
    return list
end

local function paginate(list, params)
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 100
    local out = {}
    for i = (page - 1) * per_page + 1, math.min(page * per_page, #list) do
        out[#out + 1] = list[i]
    end
    -- Feedbin answers a page past the end with 404.
    if #out == 0 and page > 1 then
        return nil
    end
    return out
end

function FakeFeedbin:entryList(params, feed_id)
    if params.ids then
        local wanted = {}
        for id in params.ids:gmatch("[^,]+") do
            wanted[tonumber(id)] = true
        end
        return self:sortedEntries(function(e) return wanted[e.id] end)
    end
    local list = self:sortedEntries(function(e)
        if feed_id and e.feed_id ~= feed_id then
            return false
        end
        if params.read == "false" and not self.unread[e.id] then
            return false
        end
        if params.starred == "true" and not self.starred[e.id] then
            return false
        end
        return true
    end)
    return paginate(list, params)
end

function FakeFeedbin:route(method, path, params, body)
    if path:sub(1, #"/parser/") == "/parser/" then
        local key = path:match("/parser/feedbin/(.*)$")
        local extraction = self.extractions[key]
        if not extraction then
            return 404, { error = "not found" }
        end
        return 200, extraction
    end

    if method == "GET" then
        if path == "/v2/subscriptions.json" then
            return 200, self.subscriptions
        elseif path == "/v2/taggings.json" then
            return 200, self.taggings
        elseif path == "/v2/unread_entries.json" then
            return 200, self:unreadIds()
        elseif path == "/v2/starred_entries.json" then
            local ids = {}
            for id in pairs(self.starred) do
                ids[#ids + 1] = id
            end
            table.sort(ids)
            return 200, ids
        elseif path == "/v2/entries.json" then
            local list = self:entryList(params)
            if not list then
                return 404, { status = 404 }
            end
            return 200, list
        end
        local feed_id = path:match("^/v2/feeds/(%d+)/entries%.json$")
        if feed_id then
            local list = self:entryList(params, tonumber(feed_id))
            if not list then
                return 404, { status = 404 }
            end
            return 200, list
        end
    elseif method == "POST" then
        local decoded = body and body ~= "" and json.decode(body) or {}
        local function apply(key, set, value)
            local ids = decoded[key] or {}
            if #ids > 1000 then
                return 400, { error = "too many ids" }
            end
            for _, id in ipairs(ids) do
                set[id] = value or nil
            end
            return 200, ids
        end
        if path == "/v2/unread_entries.json" then
            return apply("unread_entries", self.unread, true)
        elseif path == "/v2/unread_entries/delete.json" then
            return apply("unread_entries", self.unread, false)
        elseif path == "/v2/starred_entries.json" then
            return apply("starred_entries", self.starred, true)
        elseif path == "/v2/starred_entries/delete.json" then
            return apply("starred_entries", self.starred, false)
        end
    end
    return 404, { status = 404 }
end

function FakeFeedbin:handle(options)
    local url = options.url or ""
    local path, query = url:match("^https?://[^/]+(/[^?]*)%??(.*)$")
    local method = options.method or "GET"
    local body = readBody(options.source)
    local headers = options.headers or {}

    local req = { method = method, path = path or url, query = query, params = parseQuery(query), body = body, headers = headers }
    table.insert(self.requests, req)

    local code, payload
    local is_extraction = url:sub(1, #FakeFeedbin.EXTRACT_HOST) == FakeFeedbin.EXTRACT_HOST
    local expected_auth = "Basic " .. mime.b64(FakeFeedbin.EMAIL .. ":" .. FakeFeedbin.PASSWORD)
    if self.failing then
        code, payload = 500, "Internal Server Error"
    elseif not is_extraction and headers["Authorization"] ~= expected_auth then
        code, payload = 401, ""
    elseif self.raw_responses[req.path] then
        code, payload = 200, self.raw_responses[req.path]
    else
        code, payload = self:route(method, req.path, req.params, body)
    end

    local text = type(payload) == "string" and payload or json.encode(payload)
    if options.sink then
        options.sink(text)
        options.sink(nil)
    end
    return 1, code, {}, "HTTP/1.1 " .. tostring(code)
end

return FakeFeedbin
