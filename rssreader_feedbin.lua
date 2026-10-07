local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local mime = require("mime")
local socketutil = require("socketutil")
local url = require("socket.url")

-- Feedbin REST API v2: https://github.com/feedbin/feedbin-api
-- Entries carry no read or starred flag; those come from the separate
-- unread_entries / starred_entries ID lists.
local Feedbin = {}
Feedbin.__index = Feedbin

local USER_AGENT = "KOReader RSSReader"
local DEFAULT_BASE_URL = "https://api.feedbin.com"

local STORIES_PER_PAGE = 50
-- Unread counts have no endpoint of their own: the tree pages through the
-- unread entries and counts them by feed, up to this many.
local COUNT_PAGE_SIZE = 100
local COUNT_MAX_PAGES = 10
-- Most IDs unread_entries / starred_entries take per call.
local MARK_BATCH_SIZE = 1000

Feedbin.ALL_FEEDS_ID = "__feedbin_all_feeds__"
Feedbin.ALL_UNREAD_ID = "__feedbin_all_unread__"
Feedbin.STARRED_ID = "__feedbin_starred__"

local function requestWithScheme(options)
    local parsed = url.parse(options.url)
    local scheme = parsed and parsed.scheme or "http"
    if scheme == "https" then
        return https.request(options)
    end
    return http.request(options)
end

local function safe_json_decode(payload)
    if not payload or payload == "" then
        return {}
    end
    local ok, decoded = pcall(json.decode, payload)
    if ok then
        return decoded
    end
    return nil
end

local function sanitizeBaseUrl(raw)
    if type(raw) ~= "string" then
        return nil
    end
    local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
    if trimmed == "" then
        return nil
    end
    return trimmed
end

local function joinUrl(base, path)
    local normalized_base = sanitizeBaseUrl(base)
    if not normalized_base then
        return nil
    end
    local normalized_path = path or ""
    if normalized_path ~= "" and not normalized_path:match("^/") then
        normalized_path = "/" .. normalized_path
    end
    return normalized_base .. normalized_path
end

-- JSON null may decode to a sentinel rather than nil, so only accept strings.
local function stringOrNil(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

-- Feedbin timestamps are UTC ("2013-02-02T14:07:33.000000Z"); os.time reads
-- a table as local time, so shift by the local UTC offset.
local function parseUtcTimestamp(timestamp)
    if type(timestamp) ~= "string" then
        return nil
    end
    local year, month, day, hour, min, sec = timestamp:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not year then
        return nil
    end
    local as_local = os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
    })
    if not as_local then
        return nil
    end
    local offset = os.time(os.date("*t", as_local)) - os.time(os.date("!*t", as_local))
    return as_local + offset
end

local function idSet(ids)
    local set = {}
    if type(ids) == "table" then
        for _, id in ipairs(ids) do
            set[tostring(id)] = true
        end
    end
    return set
end

local function normalizeEntry(entry, unread_set, starred_set, feed_titles)
    if type(entry) ~= "table" then
        return {}
    end

    local story = {}

    if entry.id ~= nil then
        local id_str = tostring(entry.id)
        story.id = id_str
        story.story_id = id_str
    end

    if entry.feed_id ~= nil then
        local feed_id_str = tostring(entry.feed_id)
        story.feed_id = feed_id_str
        story.story_feed_id = feed_id_str
        if feed_titles and feed_titles[feed_id_str] then
            story.feed_title = feed_titles[feed_id_str]
        end
    end

    local title = stringOrNil(entry.title) or ""
    story.title = title
    story.story_title = title

    local permalink = stringOrNil(entry.url)
    story.permalink = permalink
    story.story_permalink = permalink

    local content = stringOrNil(entry.content) or stringOrNil(entry.summary) or ""
    story.content = content
    story.story_content = content

    local unix_time = parseUtcTimestamp(entry.published) or parseUtcTimestamp(entry.created_at)
    if unix_time then
        story.timestamp = unix_time * 1000
        story.created_on_time = unix_time * 1000
    end

    local read_flag = not (story.id and unread_set and unread_set[story.id])
    story.read = read_flag
    story.read_status = read_flag
    story.story_read = read_flag

    story.starred = (story.id and starred_set and starred_set[story.id]) and true or false

    local author = stringOrNil(entry.author)
    if author then
        story.author = author
    end

    return story
end

function Feedbin:new(account)
    local instance = {
        account = account or {},
        tree_cache = nil,
        subscriptions_cache = nil,
        feed_titles = {},
    }
    setmetatable(instance, self)
    return instance
end

function Feedbin:getCredentials()
    local auth = self.account and self.account.auth
    if type(auth) ~= "table" then
        return nil, nil, nil
    end

    local username = auth.username or auth.email or auth.user
    if type(username) ~= "string" or username == "" then
        username = nil
    end

    local password = auth.password
    if type(password) ~= "string" or password == "" then
        password = nil
    end

    local base_url = sanitizeBaseUrl(auth.base_url or auth.baseurl or auth.url) or DEFAULT_BASE_URL

    return username, password, base_url
end

-- Returns ok, decoded_body_or_error, http_code.
function Feedbin:performRequest(method, path, body_table)
    local username, password, base_url = self:getCredentials()

    if not username or not password then
        return false, "Missing Feedbin email or password"
    end

    local target_url = joinUrl(base_url, path)
    if not target_url then
        return false, "Unable to build Feedbin request URL"
    end

    local headers = {
        ["Accept"] = "application/json",
        ["User-Agent"] = USER_AGENT,
        ["Authorization"] = "Basic " .. mime.b64(username .. ":" .. password),
    }

    local body
    if body_table ~= nil then
        local ok, encoded = pcall(json.encode, body_table)
        if not ok then
            return false, string.format("Failed to encode request body: %s", encoded)
        end
        body = encoded
        headers["Content-Type"] = "application/json; charset=utf-8"
        headers["Content-Length"] = tostring(#body)
    end

    local response_chunks = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local _, code, _, status = requestWithScheme({
        url = target_url,
        method = method or "GET",
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response_chunks),
    })
    socketutil:reset_timeout()

    local numeric_code = tonumber(code)
    if numeric_code == 401 then
        return false, "Feedbin login failed: check the email and password", numeric_code
    end
    if not numeric_code or numeric_code < 200 or numeric_code >= 300 then
        return false, string.format("Feedbin request failed (HTTP %s - %s)", tostring(code), tostring(status)), numeric_code
    end

    local text = table.concat(response_chunks)
    if text == "" or text == "null" then
        return true, {}, numeric_code
    end

    local decoded = safe_json_decode(text)
    if type(decoded) ~= "table" then
        logger.warn("Feedbin response parse error", text or "no data")
        return false, "Unable to parse Feedbin response", numeric_code
    end

    return true, decoded, numeric_code
end

-- Fetches one page of entries. Feedbin answers 404 for a page past the end
-- (and so possibly for an empty list), which is treated as an empty page.
function Feedbin:fetchEntriesPage(path, params, page, per_page)
    local query_parts = {
        "page=" .. tostring(page),
        "per_page=" .. tostring(per_page),
    }
    for _, param in ipairs(params or {}) do
        table.insert(query_parts, param)
    end
    local ok, data, code = self:performRequest("GET", path .. "?" .. table.concat(query_parts, "&"))
    if not ok then
        if code == 404 then
            return true, {}
        end
        return false, data
    end
    return true, data
end

function Feedbin:fetchUnreadIds()
    local ok, data = self:performRequest("GET", "/v2/unread_entries.json")
    if not ok then
        return false, data
    end
    return true, data
end

function Feedbin:fetchStarredIds()
    local ok, data = self:performRequest("GET", "/v2/starred_entries.json")
    if not ok then
        return false, data
    end
    return true, data
end

function Feedbin:fetchSubscriptions(force)
    if self.subscriptions_cache and not force then
        return true, self.subscriptions_cache
    end

    local ok, data = self:performRequest("GET", "/v2/subscriptions.json")
    if not ok then
        return false, data
    end

    self.subscriptions_cache = data
    self.feed_titles = {}
    for _, subscription in ipairs(data) do
        if subscription.feed_id ~= nil then
            self.feed_titles[tostring(subscription.feed_id)] = stringOrNil(subscription.title) or "Feed"
        end
    end
    return true, data
end

-- Counts unread entries per feed, reading at most COUNT_MAX_PAGES pages.
-- Returns the counts and whether the cap cut the count short.
function Feedbin:countUnreadByFeed()
    local counts = {}
    for page = 1, COUNT_MAX_PAGES do
        local ok, entries = self:fetchEntriesPage("/v2/entries.json", { "read=false" }, page, COUNT_PAGE_SIZE)
        if not ok then
            return false, entries
        end
        for _, entry in ipairs(entries) do
            if entry.feed_id ~= nil then
                local key = tostring(entry.feed_id)
                counts[key] = (counts[key] or 0) + 1
            end
        end
        if #entries < COUNT_PAGE_SIZE then
            return true, counts, false
        end
    end
    return true, counts, true
end

function Feedbin:buildTree(force)
    if self.tree_cache and not force then
        return true, self.tree_cache
    end

    local ok_subs, subscriptions = self:fetchSubscriptions(true)
    if not ok_subs then
        return false, subscriptions
    end

    local ok_tags, taggings = self:performRequest("GET", "/v2/taggings.json")
    if not ok_tags then
        return false, taggings
    end

    -- A failed count only costs the numbers, not the tree.
    local ok_counts, counts, counts_partial = self:countUnreadByFeed()
    if not ok_counts then
        logger.warn("Feedbin unread count failed", counts)
        counts = {}
        counts_partial = false
    end

    local function makeFeedNode(subscription)
        local feed_id = tostring(subscription.feed_id)
        return {
            kind = "feed",
            id = feed_id,
            title = self.feed_titles[feed_id] or "Feed",
            feed = {
                unreadCount = counts[feed_id] or 0,
                unreadCountPartial = counts_partial,
            },
        }
    end

    local subscription_by_feed = {}
    for _, subscription in ipairs(subscriptions) do
        if subscription.feed_id ~= nil then
            subscription_by_feed[tostring(subscription.feed_id)] = subscription
        end
    end

    -- A feed can carry several tags and then shows up in each folder.
    local folder_map = {}
    local tagged = {}
    for _, tagging in ipairs(taggings) do
        local name = stringOrNil(tagging.name)
        local feed_key = tagging.feed_id ~= nil and tostring(tagging.feed_id)
        local subscription = feed_key and subscription_by_feed[feed_key]
        if name and subscription then
            local folder = folder_map[name]
            if not folder then
                folder = {
                    kind = "folder",
                    id = name,
                    title = name,
                    children = {},
                }
                folder_map[name] = folder
            end
            table.insert(folder.children, makeFeedNode(subscription))
            tagged[feed_key] = true
        end
    end

    local function byTitle(a, b)
        return (a.title or "") < (b.title or "")
    end

    local root_children = {}
    for _, folder in pairs(folder_map) do
        table.sort(folder.children, byTitle)
        table.insert(root_children, folder)
    end
    for _, subscription in ipairs(subscriptions) do
        if subscription.feed_id ~= nil and not tagged[tostring(subscription.feed_id)] then
            table.insert(root_children, makeFeedNode(subscription))
        end
    end

    table.sort(root_children, function(a, b)
        if a.kind == "folder" and b.kind == "feed" then
            return true
        elseif a.kind == "feed" and b.kind == "folder" then
            return false
        end
        return byTitle(a, b)
    end)

    -- Feedbin's entries endpoint cannot filter by tag, so the aggregated
    -- views only exist at the root.
    table.insert(root_children, 1, {
        kind = "feed",
        id = Feedbin.STARRED_ID,
        title = "★ Starred",
        _virtual = true,
    })
    table.insert(root_children, 1, {
        kind = "feed",
        id = Feedbin.ALL_UNREAD_ID,
        title = "★ All Unread",
        _virtual = true,
        _read_filter = "unread",
    })
    table.insert(root_children, 1, {
        kind = "feed",
        id = Feedbin.ALL_FEEDS_ID,
        title = "★ All Feeds",
        _virtual = true,
        _read_filter = "all",
    })

    self.tree_cache = {
        kind = "root",
        title = (self.account and self.account.name) or "Feedbin",
        children = root_children,
    }

    return true, self.tree_cache
end

function Feedbin:fetchStories(feed_id, options)
    if not feed_id then
        return false, "Missing feed identifier"
    end

    options = options or {}
    local page = options.page or 1
    if page < 1 then
        page = 1
    end

    local is_virtual = feed_id == Feedbin.ALL_FEEDS_ID
        or feed_id == Feedbin.ALL_UNREAD_ID
        or feed_id == Feedbin.STARRED_ID

    local path
    local params = {}
    if feed_id == Feedbin.ALL_FEEDS_ID then
        path = "/v2/entries.json"
    elseif feed_id == Feedbin.ALL_UNREAD_ID then
        path = "/v2/entries.json"
        table.insert(params, "read=false")
    elseif feed_id == Feedbin.STARRED_ID then
        path = "/v2/entries.json"
        table.insert(params, "starred=true")
    else
        path = "/v2/feeds/" .. url.escape(tostring(feed_id)) .. "/entries.json"
    end

    -- Story titles in virtual feeds are prefixed with the feed title.
    if is_virtual then
        local ok_subs, err = self:fetchSubscriptions()
        if not ok_subs then
            return false, err
        end
    end

    local ok_unread, unread_ids = self:fetchUnreadIds()
    if not ok_unread then
        return false, unread_ids
    end
    local ok_starred, starred_ids = self:fetchStarredIds()
    if not ok_starred then
        return false, starred_ids
    end
    local unread_set = idSet(unread_ids)
    local starred_set = idSet(starred_ids)

    local ok, entries = self:fetchEntriesPage(path, params, page, STORIES_PER_PAGE)
    if not ok then
        return false, entries
    end

    local stories = {}
    for _, entry in ipairs(entries) do
        local story = normalizeEntry(entry, unread_set, starred_set, self.feed_titles)
        if is_virtual then
            story._from_virtual_feed = true
        end
        table.insert(stories, story)
    end

    return true, {
        stories = stories,
        more_stories = #entries >= STORIES_PER_PAGE,
    }
end

local function storyIdNumber(story)
    local story_id = story and (story.id or story.story_id)
    return story_id and tonumber(story_id)
end

-- Sends ids to an unread_entries / starred_entries endpoint in batches.
-- Uses the POST .../delete.json forms rather than DELETE with a body.
function Feedbin:sendIdBatches(path, key, ids)
    for start = 1, #ids, MARK_BATCH_SIZE do
        local batch = {}
        for i = start, math.min(start + MARK_BATCH_SIZE - 1, #ids) do
            table.insert(batch, tonumber(ids[i]) or ids[i])
        end
        local ok, err = self:performRequest("POST", path, { [key] = batch })
        if not ok then
            return false, err
        end
    end
    return true
end

function Feedbin:markIdsAsRead(ids)
    return self:sendIdBatches("/v2/unread_entries/delete.json", "unread_entries", ids)
end

function Feedbin:markStoryAsRead(feed_id, story)
    local id = storyIdNumber(story)
    if not id then
        return false, "Missing story ID"
    end
    return self:markIdsAsRead({ id })
end

function Feedbin:markStoryAsUnread(feed_id, story)
    local id = storyIdNumber(story)
    if not id then
        return false, "Missing story ID"
    end
    return self:sendIdBatches("/v2/unread_entries.json", "unread_entries", { id })
end

function Feedbin:markStoryAsStarred(feed_id, story)
    local id = storyIdNumber(story)
    if not id then
        return false, "Missing story ID"
    end
    return self:sendIdBatches("/v2/starred_entries.json", "starred_entries", { id })
end

function Feedbin:markStoryAsUnstarred(feed_id, story)
    local id = storyIdNumber(story)
    if not id then
        return false, "Missing story ID"
    end
    return self:sendIdBatches("/v2/starred_entries/delete.json", "starred_entries", { id })
end

-- Collects a feed's unread entry IDs page by page.
function Feedbin:collectUnreadIdsForFeed(feed_id, into)
    local path = "/v2/feeds/" .. url.escape(tostring(feed_id)) .. "/entries.json"
    local page = 1
    while true do
        local ok, entries = self:fetchEntriesPage(path, { "read=false" }, page, COUNT_PAGE_SIZE)
        if not ok then
            return false, entries
        end
        for _, entry in ipairs(entries) do
            if entry.id ~= nil then
                table.insert(into, entry.id)
            end
        end
        if #entries < COUNT_PAGE_SIZE then
            return true, into
        end
        page = page + 1
    end
end

function Feedbin:markFeedAsRead(feed_id)
    if not feed_id then
        return false, "Missing feed identifier"
    end
    local ok, ids = self:collectUnreadIdsForFeed(feed_id, {})
    if not ok then
        return false, ids
    end
    return self:markIdsAsRead(ids)
end

-- category_id is the tag name, which is the folder's id in the tree.
function Feedbin:markCategoryAsRead(category_id)
    if not category_id then
        return false, "Missing category identifier"
    end
    local ok_tree, tree = self:buildTree()
    if not ok_tree then
        return false, tree
    end
    local folder
    for _, child in ipairs(tree.children or {}) do
        if child.kind == "folder" and child.id == category_id then
            folder = child
            break
        end
    end
    if not folder then
        return false, "Folder not found"
    end
    local ids = {}
    for _, child in ipairs(folder.children or {}) do
        if child.kind == "feed" and not child._virtual then
            local ok, err = self:collectUnreadIdsForFeed(child.id, ids)
            if not ok then
                return false, err
            end
        end
    end
    return self:markIdsAsRead(ids)
end

function Feedbin:markAllAsRead()
    local ok, ids = self:fetchUnreadIds()
    if not ok then
        return false, ids
    end
    return self:markIdsAsRead(ids)
end

function Feedbin:markStarredAsRead()
    local ok_unread, unread_ids = self:fetchUnreadIds()
    if not ok_unread then
        return false, unread_ids
    end
    local ok_starred, starred_ids = self:fetchStarredIds()
    if not ok_starred then
        return false, starred_ids
    end
    local unread_set = idSet(unread_ids)
    local ids = {}
    for _, id in ipairs(starred_ids) do
        if unread_set[tostring(id)] then
            table.insert(ids, id)
        end
    end
    return self:markIdsAsRead(ids)
end

return Feedbin
