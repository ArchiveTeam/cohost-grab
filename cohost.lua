dofile("table_show.lua")
dofile("urlcode.lua")
dofile("strict.lua")
local urlparse = require("socket.url")
local luasocket = require("socket") -- Used to get sub-second time
local http = require("socket.http")
JSON = assert(loadfile "JSON.lua")()
local fun = require("fun")

local start_urls = JSON:decode(os.getenv("start_urls"))
local items_table = JSON:decode(os.getenv("item_names_table"))
local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false

local discovered_items = {}
local discovered_urls = {}
local last_main_site_time = 0
local current_item_type = nil
local current_item_value = nil
local next_start_url_index = 1
local mystery_scripts = {}

local current_item_value_proper_capitalization = nil
local do_retry = false -- read by get_urls
local redirects_level = 0
local username_post_type = nil
local postid_post_type = nil
local pure_repost_posts = {}
local cut_user_short = false

local iframely_key = "db0b365a626eb72ce8c169cd30f99ac2"
local USERNAME_RE = "[a-zA-Z0-9%-]+"


io.stdout:setvbuf("no") -- So prints are not buffered - http://lua.2524044.n2.nabble.com/print-stdout-and-flush-td6406981.html

if urlparse == nil or http == nil then
  io.stdout:write("socket not corrently installed.\n")
  io.stdout:flush()
  abortgrab = true
end

local do_debug = false
print_debug = function(...)
  if do_debug then
    print(...)
  end
end
print_debug("This grab script is running in debug mode. You should not see this in production.")

local start_urls_inverted = {}
for _, v in pairs(start_urls) do
  start_urls_inverted[v] = true
end

-- Function to be called whenever an item's download ends.
end_of_item = function()
	current_item_value_proper_capitalization = nil
end

set_new_item = function(url)
  if url == start_urls[next_start_url_index] then
    end_of_item()
    current_item_type = items_table[next_start_url_index][1]
    current_item_value = items_table[next_start_url_index][2]
    next_start_url_index = next_start_url_index + 1
    print_debug("Setting CIT to " .. current_item_type)
    print_debug("Setting CIV to " .. current_item_value)
    mystery_scripts = {}
    pure_repost_posts = {}
    cut_user_short = false
  end
  assert(current_item_type)
  assert(current_item_value)
end

discover_item = function(item_type, item_name)
  assert(item_type)
  assert(item_name)
  -- Assert that if the page (or something in the script, erroneously) is giving us an alternate form with different capitalization, there is only one form
  if string.lower(item_name) == string.lower(current_item_value) and item_name ~= current_item_value then
    if current_item_value_proper_capitalization ~= nil then
      assert(current_item_value_proper_capitalization == item_name)
    else
      current_item_value_proper_capitalization = item_name
    end
  end

  if not discovered_items[item_type .. ":" .. item_name] then
    print_debug("Queuing for discovery " .. item_type .. ":" .. item_name)
  end
  discovered_items[item_type .. ":" .. item_name] = true
end

discover_url = function(url)
  assert(url)
  --assert(url:match(":")) disabled for this project as potential garbage is sent here
  if url:match("\n") or not url:match(":") then -- Garbage
    return
  end
  if not discovered_urls[url] then
    print_debug("Discovering for #// " .. url)
    discovered_urls[url] = true
  end
end

add_ignore = function(url)
  if url == nil then -- For recursion
    return
  end
  if downloaded[url] ~= true then
    downloaded[url] = true
  else
    return
  end
  add_ignore(string.gsub(url, "^https", "http", 1))
  add_ignore(string.gsub(url, "^http:", "https:", 1))
  add_ignore(string.match(url, "^ +([^ ]+)"))
  local protocol_and_domain_and_port = string.match(url, "^([a-zA-Z0-9]+://[^/]+)$")
  if protocol_and_domain_and_port then
    add_ignore(protocol_and_domain_and_port .. "/")
  end
  add_ignore(string.match(url, "^(.+)/$"))
end

for ignore in io.open("ignore-list", "r"):lines() do
  add_ignore(ignore)
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

allowed = function(url, parenturl, forced)
  assert(parenturl ~= nil)

  if start_urls_inverted[url] then
    return false
  end

  local tested = {}
  for s in string.gmatch(url, "([^/]+)") do
    if tested[s] == nil then
      tested[s] = 0
    end
    if tested[s] == 6 then
      return false
    end
    tested[s] = tested[s] + 1
  end
  
  if current_item_type == "tag" then
    local tag_re = "^https?://cohost%.org/rc/tagged/([^%?#]+)"
    return parenturl:match(tag_re) == url:match(tag_re)
  end
  
  if cut_user_short then
    print_debug("Cutting user short!")
    assert(current_item_type == "user")
    return false
  end
  
  -- Block potential repost media - ie stuff from the HTML of the index pages
  if (string.match(url, "^https?://staging%.cohostcdn%.org/attachment/") or string.match(url, "^https?://proxy%-staging%.cohostcdn%.org/")) and (
    string.match(parenturl, "^https?://cohost%.org/" .. USERNAME_RE .. "/?%?page=%d+$") or
    string.match(parenturl, "^https?://" .. USERNAME_RE .. "cohost%.org/%?page=%d+$") or
    string.match(parenturl, "^https?://cohost%.org/" .. USERNAME_RE .. "/?$") or
    string.match(parenturl, "^https?://" .. USERNAME_RE .. "cohost%.org/?$")) then
    print_debug("Rejecting " .. url .. " as its parent may have spurious reposts")
    return false
  end
  
  -- Block actual repost media
  if (string.match(url, "^https?://staging%.cohostcdn%.org/attachment/") or string.match(url, "^https?://proxy%-staging%.cohostcdn%.org/")) and pure_repost_posts[parenturl] then
    print_debug("Rejecting " .. url .. " as it comes from a pure repost")
    return false
  end
  

  if string.match(url, "^https?://[^/%.]+%.cohostcdn%.org/") 
  or string.match(url, "^https?://cohost.org/api/")
  or string.match(url, "^https?://cohost.org/" .. USERNAME_RE .. "/rss/")
  then
    return true
  end
  
  if string.match(url, "^https?://" .. USERNAME_RE .. "%.cohost%.org/rc/login") or string.match(url, "^https?://cohost%.org/rc/login") then
    return false
  end
  
  if string.match(url, "^https?://cohost.org/static/") then
    return false -- We still get /static on custom subdomains
  end
  
  local user = string.match(url, "^https?://cohost.org/([^/%?]+)") or string.match(url, "^https?://([^/%.]+)%.cohost.org/?")
  if user then
    if user:lower() == current_item_value:lower() then
      return true
    else
      discover_item("user", user)
      return false
    end
  end
  
  if (url:match("^https?://[^/]*%.?iframely%.net/") or url:match("^https?://[^/]*%.?iframe%.ly/")) and url ~= "https://cdn.iframe.ly/embed.js" then
    return true
  end

  if forced then
    return true -- N.b. this function is bypassed by check() anyway
  else
    discover_url(url)
    return false
  end
end



wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  --print_debug("DCP on " .. url)
  if downloaded[url] == true or addedtolist[url] == true then
    return false
  end
  -- DCP specifically is picking up garbage here that gets resolved as relative links
  local post_re = "^https?://cohost%.org/" .. USERNAME_RE .. "/post/"
  if urlpos["url"]["url"]:match(post_re) and parent["url"]:match(post_re) then
    return false
  end
  if allowed(url, parent["url"]) then
    addedtolist[url] = true
    print_debug("DCP allowed " .. url)
    return true
  end

  return false
end


-- Too much indentation leaving this in get_urls
local function check_post_attachments(post, check)  
  print_debug("Checking attachments of post " .. post["singlePostPageUrl"])
  -- sanitize.tsx
  local forceAttachmentsToTop = post["publishedAt"] < "2024-02-12T12:00:00-08:00"
  local layoutBehaviorIsV2 = post["publishedAt"] < "2024-03-27T12:00:00-08:00"

  
  -- use-image-optimizer.ts (and a few others)
  local function check_srcWithDpr(src, maxWidth, aspectRatio)
    assert(src:match("^https://[^%.]+%.cohostcdn"))
    src = src .. "?width=" .. tostring(math.floor(maxWidth))
    if aspectRatio then
      src = src .. "&height=" .. tostring(math.floor(maxWidth / aspectRatio))
      src = src .. "&fit=crop"
    end
    src = src .. "&auto=webp"
    for _, dpr in pairs({"1", "2", "3"}) do
      check(src .. "&dpr=" .. dpr)
    end
  end
  
  -- Example of GIFs (preview != download URL): https://cohost.org/AqueousAblution/post/7909814-get-eggbugged-nerds
  -- image.tsx:56 (also 22) where it gets special handling
  
  local function check_AttachmentLayoutRow(atts)
    print_debug("Total pre-filtered atts:")
    atts:each(function(b) print_debug("- " .. JSON:encode(b)) end)
    local atts = atts:map(function(block) return block["attachment"] end)
    local aspect_ratio = nil
    if atts:length() > 1 then
      local function size(att)
        return att["width"] * att["height"]
      end
      local largest_att = atts:max_by(function(a, b) if size(a) > size(b) then return a else return b end end)
      local aspect_ratio = largest_att["width"] / largest_att["height"]
    end
    local maxWidth = 675 / atts:length()
    -- :chain() is a hack to turn it back into a (gen, param, state) iterator
    for _, at in atts:chain() do
      print_debug("Processing at " .. JSON:encode(at))
      if at["kind"] == "image" then
        check_srcWithDpr(at["fileURL"], maxWidth, aspect_ratio)
        if at["previewURL"] ~= at["fileURL"] then
          assert(at["fileURL"]:match("%.gif$"))
          check_srcWithDpr(at["previewURL"], maxWidth, aspect_ratio)
        end
      elseif at["kind"] == "audio" then
        assert(at["previewURL"] == at["fileURL"])
        assert(at["fileURL"]:match("^https://[^%.]+%.cohostcdn"))
        check(at["fileURL"])
      else
        error("Unknown attachment kind " .. at["kind"])
      end
    end
  end
  
  local function check_attachment_group(atts, is_explicit_row)
    if is_explicit_row then
      assert(atts:length() < 4) -- Never seen this in the wild
    end
    -- Cannot find any examples of audio and images in the same post, except where images are all in a row - https://cohost.org/emmmmmmmm/post/7888842-empty
    -- If you do find counterexample - layouts seem to handle them specially
    if atts:length() > 1 then
      assert(not atts:any(function(a) return a["kind"] == "audio" end))
    end
    assert(atts:length() > 0)
    if layoutBehaviorIsV2 or is_explicit_row then -- post-body.tsx:279
      -- AttachmentLayoutV2 (logic here in layoutImages)
      while atts:length() > 0 do
        if atts:length() == 3 then
          check_AttachmentLayoutRow(atts:take_n(3))
          atts = atts:drop_n(3)
        else
          -- The case of length=1 is handled by this, the result of the take_n will just be small
          check_AttachmentLayoutRow(atts:take_n(2))
          atts = atts:drop_n(2)
        end
      end
    else
      -- AttachmentLayoutV1
      if atts:length() % 2 ~= 0 then -- TODO check this conditional accurately represents the TS
        check_AttachmentLayoutRow(atts:take_n(3))
        atts = atts:drop_n(3)
      end
      while atts:length() > 0 do
        check_AttachmentLayoutRow(atts:take_n(2))
        atts = atts:drop_n(2)
      end
    end
  end
  
  -- Now deal with attachments
  -- post-body.tsx:188
  if forceAttachmentsToTop then
    local blocks = fun.iter(post["blocks"])
    -- The JS flattens rows out, as if it supports them, but then seems to render them *again* when it processes the block - I am lacking an example for what actually happens here
    -- (Sadly if we need to do it like the JS/TS seems to do, Luafun doesn't have flatmap)
    assert(not blocks:any(function(b) return b["type"] == "attachment-row" end))
    local blocks = blocks:filter(function(b) return b["type"] == "attachment" end)
    if blocks:length() > 0 then
      check_attachment_group(blocks, false)
    end
  else
    local blocks = fun.iter(post["blocks"])
    while blocks:length() > 0 do
      -- Want atts to be the next run of consecutive attachments, will discard non-atts
      local atts, remainder = blocks:span(function(b) return b["type"] == "attachment" end)
      blocks = remainder:drop_while(function(b) return b["type"] ~= "attachment" end)
      if atts:length() > 0 then
        check_attachment_group(atts, false)
      end
    end
  end
  -- Explicit rows
  fun.iter(post["blocks"]):filter(function(b) return b["type"] == "attachment-row" end):map(function(b) return fun.iter(b["attachments"]) end):each(function(g) check_attachment_group(g, true) end)
  
  -- References to this in earlier versions of this script and I don't remember where it's from
  assert(not fun.iter(post["blocks"]):any(function(b) return b["type"] == "attachments" end))
end

local function process_post(post, username, check, insane_url_extract)
  check(post["singlePostPageUrl"])
  check("https://cohost.org/api/v1/trpc/login.loggedIn,users.displayPrefs,subscriptions.hasActiveSubscription,projects.isReaderMuting,projects.isReaderBlocking,projects.followingState,posts.singlePost?batch=1&input=%7B%223%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%224%22%3A%7B%22projectHandle%22%3A%22".. username .."%22%7D%2C%225%22%3A%7B%22projectHandle%22%3A%22" .. username .."%22%7D%2C%226%22%3A%7B%22handle%22%3A%22".. username .."%22%2C%22postId%22%3A".. post["postId"] .."%7D%7D")
  check("https://cohost.org/api/v1/trpc/projects.followingState,posts.singlePost,projects.isReaderMuting,projects.isReaderBlocking?batch=1&input=%7B%220%22%3A%7B%22projectHandle%22%3A%22".. username .."%22%7D%2C%221%22%3A%7B%22handle%22%3A%22".. username .."%22%2C%22postId%22%3A".. post["postId"] .."%7D%2C%222%22%3A%7B%22projectHandle%22%3A%22".. username .."%22%7D%2C%223%22%3A%7B%22projectHandle%22%3A%22".. username .."%22%7D%7D")
  check("https://cohost.org/api/v1/trpc/users.displayPrefs,projects.followingState,posts.singlePost,projects.isReaderMuting,projects.isReaderBlocking?batch=1&input=%7B%221%22%3A%7B%22projectHandle%22%3A%22".. username .."%22%7D%2C%222%22%3A%7B%22handle%22%3A%22".. username .."%22%2C%22postId%22%3A".. post["postId"] .."%7D%2C%223%22%3A%7B%22projectHandle%22%3A%22".. username .."%22%7D%2C%224%22%3A%7B%22projectHandle%22%3A%22".. username .."%22%7D%7D")
  check("https://cohost.org/api/v1/trpc/users.displayPrefs,subscriptions.hasActiveSubscription,login.loggedIn,projects.followingState,posts.singlePost,projects.isReaderMuting,projects.isReaderBlocking?batch=1&input=%7B%223%22%3A%7B%22projectHandle%22%3A%22".. username .."%22%7D%2C%224%22%3A%7B%22handle%22%3A%22".. username .."%22%2C%22postId%22%3A".. post["postId"] .."%7D%2C%225%22%3A%7B%22projectHandle%22%3A%22".. username .."%22%7D%2C%226%22%3A%7B%22projectHandle%22%3A%22".. username .."%22%7D%7D")
  

  for _, tag in pairs(post["tags"]) do
    check("https://cohost.org/" .. username .. "/tagged/" .. urlparse.escape(tag))
    -- Seemingly case is normalized site-wide before being sent in these responses, so do not need to do that for the tracker
    discover_item("tag", urlparse.escape(tag))
  end
  
  assert(post["postingProject"]["handle"]:lower() == username:lower())
  -- N.b. if it's a repost with no additions, we won't get any resources of the original because those are all in the share tree
  for _, step in pairs(post["shareTree"]) do
    discover_item("user", step["postingProject"]["handle"])
  end
  
  if #post["astMap"]["spans"] == 0 and #post["blocks"] == 0 then
    pure_repost_posts[post["singlePostPageUrl"]] = true
  else
  
    -- General extraction of links
    for _, content_block in pairs(post["blocks"]) do
      if content_block["type"] == "attachment" or content_block["type"] == "attachments" or content_block["type"] == "attachment-row" then
        -- These are dealt with in check_post_attachments
      elseif content_block["type"] == "markdown" then
        insane_url_extract(content_block["markdown"]["content"])
      elseif content_block["type"] == "ask" then
        if content_block["ask"]["askingProject"] then
          discover_item("user", content_block["ask"]["askingProject"]["handle"])
        end
      else
        error("Unknown CB type " .. content_block["type"])
      end
    end
    
    check_post_attachments(post, check)
    
    -- links from the AST - see unified-processors.ts, makeIframelyEmbeds
    local function traverse(node, only_child)
      if node["tagName"] == "a" then
        local href = node["properties"]["href"]
        discover_url(href)
        if node["children"] and #node["children"] == 1 and node["children"][1]["type"] == "text"
          and node["position"] and node["children"][1]["position"] and node["children"][1]["position"]["start"]["offset"] == node["position"]["start"]["offset"]
          and only_child then
          check("https://cdn.iframe.ly/api/iframely?url=" .. urlparse.escape(href) .. "&key=" .. iframely_key .. "&iframe=1&omit_script=1")
        else
          print_debug("Skipped getting a tag because", node["children"] ~= nil, #node["children"] == 1, node["children"][1]["type"] == "text",
          node["position"], node["children"][1]["position"], node["children"][1]["position"]["start"]["offset"] == node["position"]["start"]["offset"],
          only_child)
        end
      elseif node["tagName"] == "img" then
        check(node["properties"]["src"], true) -- Force as it is an embedded image, not a link
      elseif node["tagName"] == "Mention" then
        discover_item("user", node["properties"]["handle"])
      end
      if node["children"] then
        for _, child in pairs(node["children"]) do
          traverse(child, #node["children"] == 1)
        end
      end
    end
    
    for _, span in pairs(post["astMap"]["spans"]) do
      traverse(JSON:decode(span["ast"]))
    end
  end
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil

  downloaded[url] = true

  local function check(urla, force)
    if urla:match("^https?://iframely%.net/api/thumbnail") and not urla:match("maxwidth=") then
      check(urla .. "&maxwidth=320")
      check(urla .. "&maxwidth=640")
      check(urla .. "&maxwidth=960")
      check(urla .. "&maxwidth=1280")
    end
    assert(not force or force == true) -- Don't accidentally put something else for force
    local origurl = url
    local url = string.match(urla, "^([^#]+)")
    local url_ = string.match(url, "^(.-)%.?$")
    url_ = string.gsub(url_, "&amp;", "&")
    url_ = string.match(url_, "^(.-)%s*$")
    url_ = string.match(url_, "^(.-)%??$")
    url_ = string.match(url_, "^(.-)&?$")
    url_ = string.match(url_, "^(.-)/?$")
    if (downloaded[url_] ~= true and addedtolist[url_] ~= true)
      and (allowed(url_, origurl, force) or force) then
      print_debug("Queueing " .. url_)
      local link_expect_html = nil
      if url_:match(".*/[^/%.]+$") then -- If it doesn't have an extension - heuristic to set this so that DCP gets triggered on custom subdomains
        link_expect_html = 1
      end
      table.insert(urls, { url=url_, headers={["Accept-Language"]="en-US,en;q=0.5"}, link_expect_html=link_expect_html})
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    if not newurl then
      return
    end
    newurl = string.gsub(newurl, "\\$", "")
    if string.match(newurl, "\\[uU]002[fF]") then
      return checknewurl(string.gsub(newurl, "\\[uU]002[fF]", "/"))
    end
    if string.match(newurl, "^https?:////") then
      check((string.gsub(newurl, ":////", "://")))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^%${")) then
      check(urlparse.absolute(url, "/" .. newurl))
    end
  end
  
  local function insane_url_extract(html)
    print_debug("IUE begin")
    for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end
    -- Cohost-specific
    for username in string.gmatch(html, "[^%w]@(" .. USERNAME_RE .. ")") do
      if #username > 3 and #username < 500 then
          discover_item("user", username)
          print_debug("Heuristically discovering user:" .. username)
      end
    end
    print_debug("IUE end")
  end

  local function load_html()
    if html == nil then
      html = read_file(file)
    end
    return html
  end

  -- The check_ob() of Cohost
  local function check_profile_posts_listing(username, page)
    local template1 = "https://cohost.org/api/v1/trpc/posts.profilePosts?batch=1&input=%7B%220%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%7D"
    local template2 = "https://cohost.org/api/v1/trpc/login.loggedIn,users.displayPrefs,subscriptions.hasActiveSubscription,projects.isReaderMuting,projects.isReaderBlocking,projects.followingState,posts.profilePosts?batch=1&input=%7B%223%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%224%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%225%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%226%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%7D"
    local template3 = "https://cohost.org/api/v1/trpc/users.displayPrefs,subscriptions.hasActiveSubscription,login.loggedIn,projects.followingState,posts.profilePosts,projects.isReaderMuting,projects.isReaderBlocking?batch=1&input=%7B%223%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%224%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%2C%225%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%226%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%7D"
    local template4 = "https://cohost.org/api/v1/trpc/users.displayPrefs,projects.followingState,posts.profilePosts,projects.isReaderMuting,projects.isReaderBlocking?batch=1&input=%7B%221%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%222%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%2C%223%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%224%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%7D" -- Seems to be the same thing as template3, but playing back in WR sometimes it gets this
    local template5 = "https://cohost.org/api/v1/trpc/users.displayPrefs,posts.profilePosts?batch=1&input=%7B%221%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%7D"
    local template6 = "https://cohost.org/api/v1/trpc/login.loggedIn,subscriptions.hasActiveSubscription,projects.isReaderMuting,projects.isReaderBlocking,projects.followingState,posts.profilePosts?batch=1&input=%7B%222%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%223%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%224%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%225%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%7D" -- Only happens on pywb which I don't like
    
    local function expand(in_table, subst_pattern)
      local out = {}
      for _, str in pairs(in_table) do
        table.insert(out, (str:gsub(subst_pattern, "true")))
        table.insert(out, (str:gsub(subst_pattern, "false")))
      end
      return out
    end
    
    local function multi_expand_and_check(in_string, subst_patterns)
      local urls = {in_string}
      for _, pat in pairs(subst_patterns) do
        urls = expand(urls, pat)
      end
      for _, url in pairs(urls) do
        check(url)
      end
    end
    
    multi_expand_and_check(template1, {"||hr||", "||hs||", "||ha||"})
    multi_expand_and_check(template2, {"||hr||", "||hs||", "||ha||"})
    multi_expand_and_check(template3, {"||hr||", "||hs||", "||ha||"})
    multi_expand_and_check(template4, {"||hr||", "||hs||", "||ha||"})
    multi_expand_and_check(template5, {"||hr||", "||hs||", "||ha||"})
    multi_expand_and_check(template6, {"||hr||", "||hs||", "||ha||"})
    
    check("https://cohost.org/" .. username .. "?page=" .. tostring(page))
    check("https://" .. username:lower() .. ".cohost.org/?page=" .. tostring(page))
  end
  
    
  local function check_user_metadata(user_info)
    local function queue_avatar(url)
      check(url .. "?dpr=2&width=80&height=80&fit=cover&auto=webp", true)
    end
    check(user_info["avatarURL"], true)
    check(user_info["avatarPreviewURL"], true)
    queue_avatar(user_info["avatarURL"])
    queue_avatar(user_info["avatarPreviewURL"])
    if user_info["headerURL"] then
      check(user_info["headerURL"], true)
    end
    if user_info["headerPreviewURL"] then
      check(user_info["headerPreviewURL"], true)
    end
  
    -- As these are outlinks, do not set `force`, which mean they go to #//
    if user_info["url"] then
      check(user_info["url"])
    end
    for _, cc in pairs(user_info["contactCard"]) do
      check(cc["value"])
    end
  end

  if current_item_type == "user" then
    -- Starting point
    if url:match("^https://cohost%.org/[^/%?]+$") then
      if status_code == 200 then
        local loader_state = JSON:decode(load_html():match('<script type="application/json" id="__COHOST_LOADER_STATE__">(.-)</script>'))
        local capitalized_handle = loader_state["project-page-view"]["project"]["handle"]
        if capitalized_handle ~= current_item_value then
          assert(capitalized_handle:lower() == current_item_value:lower())
          discover_item("user", capitalized_handle)
          cut_user_short = true
        else
          check_profile_posts_listing(current_item_value, 0)
          -- https://help.antisoftware.club/support/solutions/articles/62000226634-how-do-i-change-my-username-page-name-or-handle-
          assert(current_item_value:match("^" .. USERNAME_RE .. "$"))
          check("https://" .. current_item_value:lower() .. ".cohost.org/")
          
          check_user_metadata(loader_state["project-page-view"]["project"])
          check("https://cohost.org/api/v1/trpc/users.displayPrefs,subscriptions.hasActiveSubscription,login.loggedIn,projects.followingState,projects.isReaderMuting,projects.isReaderBlocking?batch=1&input=%7B%223%22%3A%7B%22projectHandle%22%3A%22".. current_item_value .."%22%7D%2C%224%22%3A%7B%22projectHandle%22%3A%22".. current_item_value .."%22%7D%2C%225%22%3A%7B%22projectHandle%22%3A%22".. current_item_value .."%22%7D%7D")
          check("https://cohost.org/api/v1/trpc/users.displayPrefs,projects.followingState,projects.isReaderMuting,projects.isReaderBlocking?batch=1&input=%7B%221%22%3A%7B%22projectHandle%22%3A%22".. current_item_value .."%22%7D%2C%222%22%3A%7B%22projectHandle%22%3A%22".. current_item_value .."%22%7D%2C%223%22%3A%7B%22projectHandle%22%3A%22".. current_item_value .."%22%7D%7D")
        end
      end
    end
    
    -- JS retrieved thru JS
    if url:match("^https?://" .. USERNAME_RE .. "%.cohost%.org/static/runtime%.[a-f0-9]+%.js$") then
      for k, v in load_html():gmatch('%s*(%d+):%s*"(%x+)"%s*') do
        print_debug("Setting mystery_scripts[" .. k .. "] to " .. v)
        mystery_scripts[k] = v
      end
    end
    if url:match("^https?://" .. USERNAME_RE .. "%.cohost%.org/static/client%.%x+%.js$") then
      local a, b = load_html():match("await n%.e%((%d+)%)%.then%(n%.bind%(n,(%d+)%)%),")
      assert(a)
      assert(a == b)
      print_debug("Weird static script: " .. a .. " looked up as " .. tostring(mystery_scripts[a]))
      check("https://" .. current_item_value:lower() .. ".cohost.org/static/" .. a .. "." .. mystery_scripts[a] .. ".js")
    end
    
    local posts_json = url:match("^https://cohost%.org/api/v1/trpc/posts%.profilePosts%?batch=1&input=(.*)$")
    if posts_json then
      local req_json = JSON:decode(urlparse.unescape(posts_json))
      local page = req_json["0"]["page"]
      local resp_json = JSON:decode(load_html())
      
      local pagination = resp_json[1]["result"]["data"]["pagination"]
      assert(pagination["morePagesForward"]) -- Unclear what this is - I think sometimes the navigaion buttons disappear and this controls it, but can't reproduce that now
      if #resp_json[1]["result"]["data"]["posts"] > 0 then
        assert(pagination["nextPage"] == page + 1)
        check_profile_posts_listing(current_item_value, page + 1)
      end
      
      for _, post in pairs(resp_json[1]["result"]["data"]["posts"]) do
        process_post(post, current_item_value, check, insane_url_extract)
      end
    end
        
    -- All HTML pages - may apply to some of the above
    if url:match("^https?://cohost%.org/") and not url:match("^https?://cohost%.org/api/") and not url:match("^https?://cohost%.org/rc/") and not url:match("^https?://cohost%.org/" .. USERNAME_RE .. "/rss/") and not status_code == 404 then
      assert(load_html():match("IFRAMELY_KEY%\":\"" .. iframely_key .. "\""))
    end
  elseif current_item_type == "tag" then
    for username in load_html():gmatch('{"handle":"(' .. USERNAME_RE .. ')"') do
      discover_item("user", username)
    end
  elseif current_item_type == "post" then
    assert(do_debug)
    
    local username_base, postid_base = url:match("^https?://cohost%.org/(" .. USERNAME_RE .. ")/post/([0-9]+).*")
    if username_base and postid_base then
      username_post_type = username_base
      postid_post_type = postid_base
      check('https://cohost.org/api/v1/trpc/posts.singlePost?batch=1&input={"0":{"handle":"' .. username_base .. '","postId":' .. postid_base .. '}}')
    elseif url:match("^https://cohost%.org/api/v1/trpc/posts%.singlePost%?batch") then
      local json = JSON:decode(load_html())
      process_post(json[1]["result"]["data"]["post"], username_post_type, check, insane_url_extract)
    end
  end
  
  if current_item_type == "post" or current_item_type == "user" then
    if url:match("^https?://cdn%.iframe%.ly/api/iframely") then
      local json = JSON:decode(load_html())
      if not json["error"] then
        local src = json["html"]:match("iframe src=\"(https://iframely%.net/api/iframe%?.-)\"")
        check(src)
      end
    end
    
    if url:match("^https://iframely%.net/api/iframe%?") then
      insane_url_extract(load_html())
    end
  end
  
  return urls
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]

  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. "  \n")
  io.stdout:flush()


  if status_code >= 200 and status_code <= 399 then
    downloaded[url["url"]] = true
  end

  assert(not (string.match(url["url"], "^https?://[^/]*google%.com/sorry") or string.match(url["url"], "^https?://consent%.google%.com/")))

  if abortgrab == true then
    io.stdout:write("ABORTING...\n")
    io.stdout:flush()
    return wget.actions.ABORT
  end


  -- Handle redirects not in download chains
  if status_code >= 300 and status_code <= 399 and (url["url"]:match("^https://iframely%.net/api/thumbnail") or (redirects_level > 0 and redirects_level < 5)) then
    redirects_level = redirects_level + 1
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    print_debug("newloc is " .. newloc)
    if downloaded[newloc] == true or addedtolist[newloc] == true then
      tries = 0
      return wget.actions.EXIT
    else
      tries = 0
      print_debug("Following redirect to " .. newloc)
      assert(not (string.match(newloc, "^https?://[^/]*google%.com/sorry") or string.match(newloc, "^https?://consent%.google%.com/")))
      assert(not string.match(url["url"], "^https?://drive%.google%.com/file/d/.*/view$")) -- If this is a redirect, it will mess up initialization of file: items
      assert(not string.match(url["url"], "^https?://drive%.google%.com/drive/folders/[0-9A-Za-z_%-]+/?$")) -- Likewise for folder:

      addedtolist[newloc] = true
      return wget.actions.NOTHING
    end
  end
  redirects_level = 0
  
  
  do_retry = false
  local maxtries = 8
  local url_is_essential = true
  if not (url["url"]:match("^https?://cohost%.org/") or url["url"]:match("^https?://[^%.]+%.cohost%.org/") or url["url"]:match("^https?://[^%.]+%.cohostcdn%.org/")
        or url["url"]:match("^https?://cdn%.iframe%.ly/") or url["url"]:match("^https://iframely%.net/api/")) then
    maxtries = 3
    url_is_essential = false
    print_debug("Inessential URL")
  end

  -- Whitelist instead of blacklist status codes
  if status_code ~= 200
    and not (url["url"]:match("^https?://cohost%.org/[^/%?]+$") and status_code == 404)
    and not (not url_is_essential and status_code == 404)
    and not (url["url"]:match("^https?://cdn%.iframe%.ly/") and JSON:decode(read_file(http_stat["local_file"]))["error"]:match("Iframely could not fetch the given URL")) then
    print("Server returned " .. http_stat.statcode .. " (" .. err .. "). Sleeping.\n")
    do_retry = true
  end

  -- Check for rate limiting in the API (status code == 200)
  if string.match(url["url"], "^https?://cohost%.org/api/") then
      local json = JSON:decode(read_file(http_stat["local_file"]))
      if json["error"] then
        print("JSON error. Sleeping.\n")
        do_retry = true
    end
  end
  

  if do_retry then
    if tries >= maxtries then
      print("I give up...\n")
      tries = 0
      if not url_is_essential then
        return wget.actions.EXIT
      else
        print("Failed on an essential URL, aborting...")
        return wget.actions.ABORT
      end
    else
      sleep_time = math.floor(math.pow(2, tries))
      tries = tries + 1
    end
  end

  if do_retry and sleep_time > 0.001 then
    print("Sleeping " .. sleep_time .. "s")
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  end

  tries = 0
  return wget.actions.NOTHING
end


local send_binary = function(to_send, key)
  local tries = 0
  while tries < 10 do
    local body, code, headers, status = http.request(
            "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
            to_send
    )
    if code == 200 or code == 409 then
      break
    end
    print("Failed to submit discovered URLs." .. tostring(code) .. " " .. tostring(body)) -- From arkiver https://github.com/ArchiveTeam/vlive-grab/blob/master/vlive.lua
    os.execute("sleep " .. math.floor(math.pow(2, tries)))
    tries = tries + 1
  end
  if tries == 10 then
    abortgrab = true
  end
end

-- Taken verbatim from previous projects I've done'
local queue_list_to = function(list, key)
  assert(key)
  if do_debug then
    for item, _ in pairs(list) do
      print("Would have sent discovered item " .. item)
    end
  else
    local to_send = nil
    for item, _ in pairs(list) do
      assert(string.match(item, ":")) -- Message from EggplantN, #binnedtray (search "colon"?)
      if to_send == nil then
        to_send = item
      else
        to_send = to_send .. "\0" .. item
      end
      print("Queued " .. item)

      if #to_send > 1500 then
        send_binary(to_send .. "\0", key)
        to_send = ""
      end
    end

    if to_send ~= nil and #to_send > 0 then
      send_binary(to_send .. "\0", key)
    end
  end
end


wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  end_of_item()
  queue_list_to(discovered_items, "cohost-wewri2htv6akk1ij")
  queue_list_to(discovered_urls, "urls-eucpu0yrat3fsajp")
end

wget.callbacks.write_to_warc = function(url, http_stat)
  set_new_item(url["url"])
  if string.match(url["url"], "^https?://cohost%.org/api/") then
    local json = JSON:decode(read_file(http_stat["local_file"]))
    if not json then
      error("Failed to parse as JSON the response from " .. url["url"] .. " : " .. read_file(http_stat["local_file"]))
    end
    if json["error"] then
      print_debug("Not WTW")
      return false
    end
  elseif (string.match(url["url"], "^https?://cohost%.org/") or string.match(url["url"], "^https?://[^%.]+%.cohost%.org/") or string.match(url["url"], "^https?://[^%.]+%.cohostcdn%.org/"))
          and http_stat["statcode"] ~= 200 and http_stat["statcode"] ~= 404 then
    print_debug("Not WTW")
    return false
  end
  return true
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if abortgrab == true then
    return wget.exits.IO_FAIL
  end
  return exit_status
end

