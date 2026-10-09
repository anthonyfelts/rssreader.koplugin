local T = dofile(os.getenv("RSSREADER_REPO") .. "/spec/helper.lua")
local FakeFeedbin = require("fake_feedbin")
local FeedbinSanitizer = require("sanitizers/rssreader_sanitizer_feedbin")
local utils = require("rssreader_menu_utils")

local ARTICLE = "<p>" .. string.rep("A clean article paragraph. ", 20) .. "</p>"

local function fetch(url)
    local html, err
    FeedbinSanitizer.fetchArticle(url, function(payload, fetch_err)
        html = FeedbinSanitizer.parseResponse(payload)
        err = fetch_err
    end)
    return html, err
end

T.describe("Feedbin sanitizer", function()
    T.it("only applies to stories that carry Feedbin's extraction link", function()
        T.eq(FeedbinSanitizer.extractionUrl({ permalink = "https://example.com/a" }), nil)
        T.eq(FeedbinSanitizer.extractionUrl({ extracted_content_url = "" }), nil)
        T.eq(FeedbinSanitizer.extractionUrl(nil), nil)
        T.eq(FeedbinSanitizer.extractionUrl({ extracted_content_url = "https://x/y" }), "https://x/y")
    end)

    T.it("returns the extracted article HTML, without sending credentials", function()
        local server = FakeFeedbin.new({
            extractions = { sig1 = { title = "Article", content = ARTICLE, word_count = 100 } },
        }):install()
        local html = fetch(FakeFeedbin.EXTRACT_HOST .. "/parser/feedbin/sig1")
        T.eq(html, ARTICLE)
        T.truthy(FeedbinSanitizer.contentIsMeaningful(html))
        T.eq(#server.requests, 1)
        T.eq(server.requests[1].headers["Authorization"], nil, "Authorization header")
        server:uninstall()
    end)

    T.it("gives up on a failed extraction so the next sanitizer runs", function()
        local server = FakeFeedbin.new():install()
        local html, err = fetch(FakeFeedbin.EXTRACT_HOST .. "/parser/feedbin/missing")
        T.eq(html, nil)
        T.truthy(err, "an error is passed on")
        server:uninstall()
    end)

    T.it("treats an empty or tiny extraction as unusable", function()
        T.eq(FeedbinSanitizer.parseResponse('{"content":""}'), nil)
        T.eq(FeedbinSanitizer.parseResponse('{"content":null}'), nil)
        -- Not JSON at all: LuaJSON aborted KOReader on these, even under pcall.
        T.eq(FeedbinSanitizer.parseResponse("not json"), nil)
        T.eq(FeedbinSanitizer.parseResponse("<html>Please log in</html>"), nil)
        T.falsy(FeedbinSanitizer.contentIsMeaningful("<p>Too short</p>"))
    end)

    T.it("sorts first among the active sanitizers with the sample config's order 0", function()
        local builder = { accounts = { config = { sanitizers = {
            { order = 1, type = "fivefilters", active = true, base_url = "https://ftr.example" },
            { order = 0, type = "feedbin", active = true },
            { order = 2, type = "diffbot", active = false },
        } } } }
        local active = utils.collectActiveSanitizers(builder)
        T.eq(#active, 2)
        T.eq(active[1].type, "feedbin")
        T.eq(active[2].type, "fivefilters")
    end)
end)

T.describe("titleFilenameComponent", function()
    T.it("keeps ordinary titles readable", function()
        T.eq(utils.titleFilenameComponent("why you should(n't) smoke"), "why_you_should(n't)_smoke")
        T.eq(utils.titleFilenameComponent("Rock & Roll"), "Rock_&_Roll")
    end)

    T.it("never returns an empty name", function()
        T.eq(utils.titleFilenameComponent("???"), "story")
        T.eq(utils.titleFilenameComponent("..."), "story")
        T.eq(utils.titleFilenameComponent(""), "story")
        T.eq(utils.titleFilenameComponent(nil), "story")
    end)

    T.it("caps long titles at 64 bytes without splitting a character", function()
        local long = utils.titleFilenameComponent(string.rep("Long title ", 40))
        T.eq(#long, 64)
        local accented = utils.titleFilenameComponent(string.rep("é", 40))
        T.eq(#accented, 64)
        T.eq(accented, string.rep("é", 32))
        -- 63 ASCII bytes then a 2-byte character: the character must go whole.
        local edge = utils.titleFilenameComponent(string.rep("a", 63) .. "é")
        T.eq(edge, string.rep("a", 63))
    end)
end)

T.finish()
