dofile("table_show.lua")
dofile("urlcode.lua")
dofile("strict.lua")
local urlparse = require("socket.url")
local luasocket = require("socket") -- Used to get sub-second time
local http = require("socket.http")
JSON = assert(loadfile "JSON.lua")()
CJSON = require "cjson"
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
local current_user = nil

local current_item_value_proper_capitalization = nil
local do_retry = false -- read by get_urls
local redirects_level = 0
local username_post_type = nil
local postid_post_type = nil
local pure_repost_posts = {}
local cut_user_short = false
local user_not_publicly_viewable = false

local tag_or_tagext_tag_content = nil
local tag_or_tagext_timestamp = nil
local tag_or_tagext_start_offset = nil -- Inclusive
local tag_or_tagext_end_offset = nil -- Exclusive
local tag_or_tagext_do_saturate = nil


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

-- CJSON wrapper that turns it into JSON.lua format
-- Needed because in some cases I do "if [field]" and it'd take a lot of work to figure out if I'm checking for presence or checking for null
local function json_decode(s)
  local function convert(o)
    if type(o) == "table" then
      local new = {}
      for k, v in pairs(o) do
        if v ~= CJSON.null then
          new[k] = convert(v)
        end
      end
      return new
    else
      return o
    end
  end
  
  local function recursive_assert_equals(a, b)
    assert(type(a) == type(b))
    if type(a) == "table" then
      for k, v in pairs(a) do
        recursive_assert_equals(v, b[k])
      end
      for k, _ in pairs(b) do
        assert(a[k] ~= nil)
      end
    else
      assert(a == b, tostring(a) .. tostring(b))
    end
  end
  
  local out = convert(CJSON.decode(s))
  --recursive_assert_equals(out, JSON:decode(s))
  return out
end

local start_urls_inverted = {}
for _, v in pairs(start_urls) do
  start_urls_inverted[v] = true
end

-- Function to be called whenever an item's download ends.
end_of_item = function()
	current_item_value_proper_capitalization = nil
end

set_new_item = function(url)
  -- If next exists, and it matches the current
  if start_urls[next_start_url_index] and (urlparse.unescape(url) == urlparse.unescape(start_urls[next_start_url_index])) then
    end_of_item()
    current_item_type = items_table[next_start_url_index][1]
    current_item_value = items_table[next_start_url_index][2]
    next_start_url_index = next_start_url_index + 1
    print_debug("Setting CIT to " .. current_item_type)
    print_debug("Setting CIV to " .. current_item_value)
    mystery_scripts = {}
    pure_repost_posts = {}
    cut_user_short = false
    user_not_publicly_viewable = false
    
    if current_item_type == "tag" then
      tag_or_tagext_tag_content = current_item_value
      tag_or_tagext_timestamp = nil
      tag_or_tagext_start_offset = 0
      tag_or_tagext_end_offset = 50
      tag_or_tagext_do_saturate = false
    elseif current_item_type == "tagext" then
      tag_or_tagext_start_offset, tag_or_tagext_timestamp, tag_or_tagext_tag_content = current_item_value:match("^([0-9]+)/([0-9]+)/(.+)$")
      tag_or_tagext_start_offset = tonumber(tag_or_tagext_start_offset)
      tag_or_tagext_end_offset = tag_or_tagext_start_offset + 50
      tag_or_tagext_do_saturate = false
    elseif current_item_type == "user" then
      current_user = current_item_value:match("^([^%+]+)")
    elseif current_item_type == "userfix1" then
      current_user = current_item_value
    elseif current_item_type == "userfix2" then
      current_user = current_item_value:match("^([^%+]+)")
    end
  end
  assert(current_item_type)
  assert(current_item_value)
end

discover_item = function(item_type, item_name)
  print_debug("Trying to discover " .. item_type .. ":" .. item_name)
  assert(item_type)
  assert(item_name)
  -- Assert that if the page (or something in the script, erroneously) is giving us an alternate form with different capitalization, there is only one form
  if item_type == "user" and current_item_type == "user" and string.lower(item_name) == string.lower(current_item_value) and item_name ~= current_item_value then
    if current_item_value_proper_capitalization ~= nil then
      assert(current_item_value_proper_capitalization == item_name)
    else
      current_item_value_proper_capitalization = item_name
    end
  end
  if item_type == "user" then
    assert(item_name:match("^" .. USERNAME_RE .. "$") or item_name:match("^" .. USERNAME_RE .. "%+%d+$"))
  end

  if not discovered_items[item_type .. ":" .. item_name] then
    print_debug("Queuing for discovery " .. item_type .. ":" .. item_name)
  end
  discovered_items[item_type .. ":" .. item_name] = true
end

discover_url = function(url)
  assert(url)
  --assert(url:match(":")) disabled for this project as potential garbage is sent here
  if url:match("\n") or not url:match(":") or #url > 500 or url:match("%s") then -- Garbage
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
  print_debug("Allowed on " .. url)
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
  
  if url == "https://cohost.org/sanqui/tagged/&" then
    -- Started timing out for no reason, causing tests to fail
    return false
  end
  
  if #url > 5000 and (url:match("data:[a-z]+/[a-zA-Z0-9%-%+_]+;base64")) then
    return false
  end
  
  if current_item_type == "tag" or current_item_type == "tagext" then
    local pr_tag, pr_timestamp, pr_offset = url:match("^https://cohost%.org/rc/tagged/(.+)%?refTimestamp=([0-9]+)&skipPosts=([0-9]+)")
    if not pr_timestamp then -- Only happens when getting a link back to offset=0, which then becomes implicit/gets removed - if it's our tag we already have it, if it's another don't care
      return false
    elseif pr_tag ~= tag_or_tagext_tag_content then
      return false
    end
    
    assert((not tag_or_tagext_timestamp) or tag_or_tagext_timestamp == pr_timestamp)
    tag_or_tagext_timestamp = pr_timestamp
    
    if current_item_type == "tagext" then
      assert(current_item_value:match(".*" .. pr_timestamp .. ".*"))
    end
    
    if tonumber(pr_offset) >= tag_or_tagext_end_offset then
      discover_item("tagext", tag_or_tagext_end_offset .. "/" .. pr_timestamp .. "/" .. pr_tag)
      tag_or_tagext_do_saturate = true
    elseif tonumber(pr_offset) < tag_or_tagext_start_offset then
      return false -- Its item had to run in order for this one to be discovered
    else
      return true
    end
    
  end
  
  if cut_user_short then
    print_debug("Cutting user short!")
    assert(current_item_type == "user" or current_item_type == "userfix2")
    return false
  end
  
  -- Disabling this section as we are getting into edge-cases in attachments and I do not want to miss stuff that DCP picks up on just because I'm trying to save a few GB
  --[[
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
  end]]
  
  if current_item_type == "usertag" then
    local user, tag = string.match(url, "^https://cohost%.org/(" .. USERNAME_RE .. ")/tagged/([^%?/%#]+)")
    if not user then
      return false
    end
    return user .. "/" .. tag == current_item_value
  end
    

  if string.match(url, "^https?://[^/%.]+%.cohostcdn%.org/") 
  or string.match(url, "^https?://cohost.org/api/")
  or string.match(url, "^https?://cohost.org/" .. USERNAME_RE .. "/rss/")
  then
    return true
  end
  
  if string.match(url, "^https?://" .. USERNAME_RE .. "%.cohost%.org/rc/login") or string.match(url, "^https?://cohost%.org/rc/login")
    or string.match(url, "^https?://cohost%.org/" .. USERNAME_RE .. "/post/compose") then
    return false
  end
  
  -- Weird form linked from https://cohost.org/heckscaper/post/434597-cohost-generates-rss
  if string.match(url, "^https?://" .. USERNAME_RE .. "%.cohost%.org/rss/public$") then
    return false
  end
  
  if string.match(url, "^https?://cohost.org/static/") then
    discover_url(url)
    return false -- We still get /static on custom subdomains
  end
  
  
  
  local user = string.match(url, "^https?://cohost.org/([^/%?]+)") or string.match(url, "^https?://([^/%.]+)%.cohost.org/?")
  if user then
    if (current_item_type == "user" or current_item_type == "userfix2") and user:lower() == current_user:lower() then
      print_debug("Is current user")
      local tag = string.match(url, "^https://cohost%.org/" .. USERNAME_RE .. "/tagged/([^%?/%#]+)")
      if tag then
        discover_item("usertag", current_user .. "/" .. tag)
        return false
      end
      if string.match(url, "^https?://" .. USERNAME_RE .. "%.cohost%.org/static/") then
        -- Only need to get these once
        print_debug("Considering static")
        return not current_item_value:match("%+")
      end
      local page = string.match(url, "^https?://cohost.org/[^/%?]+/?%?page=([0-9]+)$") or string.match(url, "^https?://[^/%.]+%.cohost.org/?%?page=([0-9]+)$")
        or ((string.match(url, "^https?://cohost.org/([^/%?]+)$") or string.match(url, "^https?://([^/%.]+)%.cohost.org/?$")) and "0")
      if page then
        local target_page = current_item_value:match("%+([0-9]+)$") or "0"
        return page == target_page
      else
        return true
      end
    else
      if user:match("^" .. USERNAME_RE .. "$") then
        discover_item("user", user)
      end
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
  
  -- Copied from allowed()
  if string.match(url, "^https?://cohost.org/static/") then
    discover_url(url)
    return false -- We still get /static on custom subdomains
  end
  
  -- As this is for purposes of debugging the attachment parsing (mostly), do not extract any of these
  if current_item_type == "post" then
    return false
  end
  
  if current_item_type == "userfix1" then
    return false
  end
  
  -- Only thing we need to DCP here are resources from subdomains; everything else is queued explicitly to avoid duplicating media
  if current_item_type == "userfix2" and not url:match("^https?://" .. USERNAME_RE .. "%.cohost%.org/static/") then
    return false
  end
  
  -- DCP specifically is picking up garbage here that gets resolved as relative links
  local post_re = "^https?://cohost%.org/" .. USERNAME_RE .. "/post/"
  if urlpos["url"]["url"]:match(post_re) and parent["url"]:match(post_re) then
    return false
  end
  print_debug("DCP info", urlpos["url"]["url"], urlpos["link_expect_html"], urlpos["link_inline_p"])
  -- More stuff that DCP and only DCP is picking up (posts discussing Cohost internals/URLs)
  if (parent["url"]:match("^https?://cohost%.org/" .. USERNAME_RE .. "/") or parent["url"]:match("^https?://" .. USERNAME_RE .. "cohost%.org/"))
    and (urlpos["url"]["url"]:match("^https?://cohost%.org/api/") or urlpos["url"]["url"]:match("^https?://" .. USERNAME_RE .. "%.cohost%.org/rss/") or urlpos["url"]["url"]:match("^https?://cohost%.org/" .. USERNAME_RE .. "/rss/" ))
    and urlpos["link_expect_html"] == 1 and urlpos["link_inline_p"] == 0 then
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
  local layoutBehaviorIsV2 = post["publishedAt"] >= "2024-03-27T12:00:00-08:00"

  
  -- use-image-optimizer.ts (and a few others)
  local function check_srcWithDpr(src, maxWidth, aspectRatio)
    print_debug("Checking DPR", src, maxWidth, aspectRatio)
    assert(src:match("^https://[^%.]+%.cohostcdn") or src:match("^https?://cohost%.org/static/"))
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
        return (att["width"] or 0) * (att["height"] or 0)
      end
      local largest_att = atts:max_by(function(a, b) if size(a) >= size(b) then return a else return b end end)
      if largest_att["kind"] == "image" and size(largest_att) > 0 then
        aspect_ratio = largest_att["width"] / largest_att["height"]
        print_debug("Setting AR per", largest_att["width"], largest_att["height"])
      else
        assert(size(largest_att) == 0 and largest_att["width"] == nil and largest_att["height"] == nil) -- True whether non-image or image without size
        aspect_ratio = 16/9;
        print_debug("Defaulting AR per", JSON:encode(largest_att))
      end
    end
    local maxWidth = 675 / atts:length()
    -- :chain() is a hack to turn it back into a (gen, param, state) iterator
    for _, at in atts:chain() do
      print_debug("Processing at " .. JSON:encode(at))
      if at["kind"] == "image" then
        check_srcWithDpr(at["fileURL"], maxWidth, aspect_ratio)
        check(at["fileURL"])
        check(at["previewURL"])
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
      assert(atts:length() < 4 or atts:length() % 2 == 0 or layoutBehaviorIsV2)
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
      if atts:length() % 2 ~= 0 then
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
    -- If normal attachement blocks and rows are mixed, it looks like the posts within rows get rendered twice
    --  after they are flattened down into attachmentBlocks
    -- https://cohost.org/scatterbrain/post/4218817-roundup-of-the-choic demonstrates what happens when it is *all* rows; all non-rows are very common
    assert((not blocks:any(function(b) return b["type"] == "attachment-row" end))
        or (not blocks:any(function(b) return b["type"] == "attachment" end)))
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
    if #tag < 1000 then
      discover_item("usertag", username .. "/" .. urlparse.escape(tag))
      -- Seemingly case is normalized site-wide before being sent in these responses, so do not need to do that for the tracker
      discover_item("tag", urlparse.escape(tag))
    end
  end
  
  assert(post["postingProject"]["handle"]:lower() == username:lower())
  -- N.b. if it's a repost with no additions, we won't get any resources of the original because those are all in the share tree
  for _, step in pairs(post["shareTree"]) do
    discover_item("user", step["postingProject"]["handle"])
  end
  
  print_debug("Checking " .. post["singlePostPageUrl"] .. " for pure repost")
  if #post["astMap"]["spans"] == 0 and #post["blocks"] == 0 then
    print_debug("Post is pure repost")
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
      -- print_debug("Traversing", JSON:encode(node))
      if node["tagName"] == "a" then
        local href = node["properties"]["href"]
        if href and href:match("^https?://") then
          print_debug("Checking href from ast " .. href)
          check(href)
          
          if node["children"] and #node["children"] == 1 and node["children"][1]["type"] == "text"
            and node["position"] and node["children"][1]["position"] and node["children"][1]["position"]["start"]["offset"] == node["position"]["start"]["offset"]
            and only_child then
            check("https://cdn.iframe.ly/api/iframely?url=" .. urlparse.escape(href) .. "&key=" .. iframely_key .. "&iframe=1&omit_script=1")
          else
            --[[print_debug("Skipped getting a tag because", node["children"] ~= nil, #node["children"] == 1, node["children"][1]["type"] == "text",
            node["position"], node["children"][1]["position"], node["children"][1]["position"]["start"]["offset"] == node["position"]["start"]["offset"],
            only_child)]]
          end
        end
      elseif node["tagName"] == "img" then
        local src = node["properties"]["src"]
        if src and src:match("^https?://") then
          check(src, not src:match("^https?://cohost%.org/")) -- Force as it is an embedded image, not a link - unless it links to Cohost proper
        end
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
      traverse(json_decode(span["ast"]))
    end
  end
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil

  downloaded[url] = true

  local function check(urla, force)
    assert(urla:match("^https?://"))
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
  
  -- prevent insane_url_extract from resolving relative links to here
  local function check_no_api(urla)
    if not urla:match("^https?://cohost%.org/api/") then
      check(urla)
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
      check_no_api((string.gsub(newurl, ":////", "://")))
    elseif string.match(newurl, "^https?://") then
      check_no_api(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check_no_api((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check_no_api(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^/") then
      check_no_api(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check_no_api(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check_no_api(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if string.match(newurl, "^%?") then
      check_no_api(urlparse.absolute(url, newurl))
    elseif not (string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^%${")) then
      check_no_api(urlparse.absolute(url, "/" .. newurl))
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
          -- Check so that it doesn't trip up the canonical-capitalization detection in discover_item
          if username:lower() ~= current_item_value:lower() then
            discover_item("user", username)
            print_debug("Heuristically discovering user:" .. username)
          end
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
  local function check_profile_posts_listing_batch(username, page, fix_only)
    local template1 = "https://cohost.org/api/v1/trpc/posts.profilePosts?batch=1&input=%7B%220%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%7D"
    local template2 = "https://cohost.org/api/v1/trpc/login.loggedIn,users.displayPrefs,subscriptions.hasActiveSubscription,projects.isReaderMuting,projects.isReaderBlocking,projects.followingState,posts.profilePosts?batch=1&input=%7B%223%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%224%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%225%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%226%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%7D"
    local template3 = "https://cohost.org/api/v1/trpc/users.displayPrefs,subscriptions.hasActiveSubscription,login.loggedIn,projects.followingState,posts.profilePosts,projects.isReaderMuting,projects.isReaderBlocking?batch=1&input=%7B%223%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%224%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%2C%225%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%226%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%7D"
    local template4 = "https://cohost.org/api/v1/trpc/users.displayPrefs,projects.followingState,posts.profilePosts,projects.isReaderMuting,projects.isReaderBlocking?batch=1&input=%7B%221%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%222%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%2C%223%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%224%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%7D" -- Seems to be the same thing as template3, but playing back in WR sometimes it gets this
    local template5 = "https://cohost.org/api/v1/trpc/users.displayPrefs,posts.profilePosts?batch=1&input=%7B%221%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%7D"
    local template6 = "https://cohost.org/api/v1/trpc/login.loggedIn,subscriptions.hasActiveSubscription,projects.isReaderMuting,projects.isReaderBlocking,projects.followingState,posts.profilePosts?batch=1&input=%7B%222%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%223%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%224%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%225%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%7D" -- Only happens on pywb which I don't like
    --- Everything after here needs to be queued retroactively - stuff that only happens in the WBM
    local template7 = "https://cohost.org/api/v1/trpc/projects.followingState,posts.profilePosts,projects.isReaderMuting,projects.isReaderBlocking?batch=1&input=%7B%220%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%221%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%2C%222%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%223%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%7D"
    local template8 = "https://cohost.org/api/v1/trpc/projects.isReaderMuting,projects.isReaderBlocking?batch=1&input=%7B%220%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%221%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%7D"
    local template9 = "https://cohost.org/api/v1/trpc/users.displayPrefs,subscriptions.hasActiveSubscription,projects.isReaderMuting,projects.isReaderBlocking,projects.followingState,posts.profilePosts?batch=1&input=%7B%222%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%223%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%224%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%225%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%7D"
    local template10 = "https://cohost.org/api/v1/trpc/projects.followingState,posts.profilePosts?batch=1&input=%7B%220%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%7D%2C%221%22%3A%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D%7D"
    
    local function check_limited_sub(template)
      template = template:gsub("||h[ra]||", "false")
      check((template:gsub("||hs||", "true")))
      check((template:gsub("||hs||", "false")))
    end
    
    if not fix_only then
      check_limited_sub(template2)
      check_limited_sub(template1)
      check_limited_sub(template3)
      check_limited_sub(template4)
      check_limited_sub(template5)
      check_limited_sub(template6)
    end
    check_limited_sub(template7)
    check_limited_sub(template8)
    check_limited_sub(template9)
    check_limited_sub(template10)
    
    if not fix_only then
      check("https://cohost.org/" .. username .. "?page=" .. tostring(page))
      check("https://" .. username:lower() .. ".cohost.org/?page=" .. tostring(page))
    end
  end


  local function check_profile_posts_listing_singles(username, page, fix_only)
    local template1 = "https://cohost.org/api/v1/trpc/posts.profilePosts?input=%7B%22projectHandle%22%3A%22" .. username .. "%22%2C%22page%22%3A" .. tostring(page) .. "%2C%22options%22%3A%7B%22pinnedPostsAtTop%22%3Atrue%2C%22hideReplies%22%3A||hr||%2C%22hideShares%22%3A||hs||%2C%22hideAsks%22%3A||ha||%2C%22viewingOnProjectPage%22%3Atrue%7D%7D"
        
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
    

    check("https://cohost.org/" .. username .. "?page=" .. tostring(page) .. "&hideShares=true")
    check("https://cohost.org/" .. username .. "?page=" .. tostring(page))
    check("https://" .. username:lower() .. ".cohost.org/?page=" .. tostring(page) .. "&hideShares=true")
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
    if user_info["url"] and user_info["url"]:match("[^%s]") then
      check(user_info["url"])
    end
    for _, cc in pairs(user_info["contactCard"]) do
      if cc["value"]:match("^https?://") then
        check(cc["value"])
      end
    end
  end
  
  
  if current_item_type == "user" or current_item_type == "userfix2" then
    if url:match("^https://cohost%.org/[^/%?]+$") then
      assert(not current_item_value:match("%+"))
      if status_code == 200 then
        local loader_state = json_decode(load_html():match('<script type="application/json" id="__COHOST_LOADER_STATE__">(.-)</script>'))
        local capitalized_handle = loader_state["project-page-view"]["project"]["handle"]
        
        if load_html():match('<h1 class="text%-xl font%-bold">this page is not viewable by logged%-out users</h1>')
          or load_html():match('<h1 class="text%-xl font%-bold">this page is private</h1>')
          or loader_state["project-page-view"]["project"]["flags"][1] == "suspended" and loader_state["project-page-view"]["canAccessPermissions"]["canRead"] ~= "allowed" then
          print_debug("User not publicly viewable")
          user_not_publicly_viewable = true
        end
        
        if capitalized_handle ~= current_user then
          assert(capitalized_handle:lower() == current_user:lower())
          discover_item(current_item_type, capitalized_handle)
          print_debug("Cutting user short")
          cut_user_short = true
        end
      end
    end
  
    if not current_item_value:match("%+") then
      -- JSON retrieved thru JS
      if url:match("^https?://" .. USERNAME_RE .. "%.cohost%.org/[^/]+$") and status_code == 200 then -- Match HTML pages on subdomain
        local version = CJSON.decode(load_html():match('<script type="application/json" id="env%-vars">(.-)</script>'))["VERSION"]
        check("https://" .. current_user:lower() .. ".cohost.org/rc/locales/en/client.json?" .. version)
        check("https://" .. current_user:lower() .. ".cohost.org/rc/locales/en/common.json?" .. version)
        check("https://" .. current_user:lower() .. ".cohost.org/rc/locales/en/server.json?" .. version)
        check("https://" .. current_user:lower() .. ".cohost.org/static/manifest.json?" .. version)
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
        check("https://" .. current_user:lower() .. ".cohost.org/static/" .. a .. "." .. mystery_scripts[a] .. ".js")
      end
    end
  end

  if current_item_type == "user" then
    -- Starting point for non-"+" users
    if url:match("^https://cohost%.org/[^/%?]+$") then
      assert(not current_item_value:match("%+"))
      if status_code == 200 and not cut_user_short then
        -- https://help.antisoftware.club/support/solutions/articles/62000226634-how-do-i-change-my-username-page-name-or-handle-
        assert(current_user:match("^" .. USERNAME_RE .. "$"))
        check("https://" .. current_user:lower() .. ".cohost.org/")
        
        -- Loader state extraction is duplicated
        local loader_state = json_decode(load_html():match('<script type="application/json" id="__COHOST_LOADER_STATE__">(.-)</script>'))
        local capitalized_handle = loader_state["project-page-view"]["project"]["handle"]
        
        check_user_metadata(loader_state["project-page-view"]["project"])
        
        if not user_not_publicly_viewable then
          print_debug("User is publicly viewable")
          check_profile_posts_listing_batch(current_user, 0)
          check("https://cohost.org/api/v1/trpc/users.displayPrefs,subscriptions.hasActiveSubscription,login.loggedIn,projects.followingState,projects.isReaderMuting,projects.isReaderBlocking?batch=1&input=%7B%223%22%3A%7B%22projectHandle%22%3A%22".. current_user .."%22%7D%2C%224%22%3A%7B%22projectHandle%22%3A%22".. current_user .."%22%7D%2C%225%22%3A%7B%22projectHandle%22%3A%22".. current_user .."%22%7D%7D")
          check("https://cohost.org/api/v1/trpc/users.displayPrefs,projects.followingState,projects.isReaderMuting,projects.isReaderBlocking?batch=1&input=%7B%221%22%3A%7B%22projectHandle%22%3A%22".. current_user .."%22%7D%2C%222%22%3A%7B%22projectHandle%22%3A%22".. current_user .."%22%7D%2C%223%22%3A%7B%22projectHandle%22%3A%22".. current_user .."%22%7D%7D")
        end
      end
    end
    
    -- Starting point for "+" users
    if current_item_value:match("%+") and url:match("^https://cohost%.org/" .. USERNAME_RE .. "?page=[0-9]+$") then
      local page_number = current_item_value:match("%+([0-9]+)$")
      if status_code ~= 404 then
        check_profile_posts_listing_batch(current_user, tonumber(page_number))
      end
    end
    
    local posts_json = url:match("^https://cohost%.org/api/v1/trpc/posts%.profilePosts%?batch=1&input=(.*)$")
    if posts_json then
      local req_json = json_decode(urlparse.unescape(posts_json))
      local page = req_json["0"]["page"]
      assert(page == tonumber((current_item_value:match("%+([0-9]+)$"))) or 0)
      local resp_json = json_decode(load_html())
      
      local pagination = resp_json[1]["result"]["data"]["pagination"]
      assert(pagination["morePagesForward"]) -- Unclear what this is - I think sometimes the navigaion buttons disappear and this controls it, but can't reproduce that now
      if #resp_json[1]["result"]["data"]["posts"] > 0 then
        assert(pagination["nextPage"] == page + 1)
        discover_item("user", current_user .. "+" .. tostring(page + 1))
      end
      
      for _, post in pairs(resp_json[1]["result"]["data"]["posts"]) do
        process_post(post, current_user, check, insane_url_extract)
      end
    end
        
    -- All HTML pages - may apply to some of the above
    if url:match("^https?://cohost%.org/") and not url:match("^https?://cohost%.org/api/") and not url:match("^https?://cohost%.org/rc/") and not url:match("^https?://cohost%.org/" .. USERNAME_RE .. "/rss/") and not status_code == 404 then
      assert(load_html():match("IFRAMELY_KEY%\":\"" .. iframely_key .. "\""))
    end
  elseif current_item_type == "tag" or current_item_type == "tagext" then
    for username in load_html():gmatch('{"handle":"(' .. USERNAME_RE .. ')"') do
      discover_item("user", username)
    end
    if tag_or_tagext_do_saturate or tag_or_tagext_start_offset > 0 then
      print_debug("Carrying out saturation...")
      -- In big tags, due to deletions(?), offsets are often not multiples of 20; and in a way I haven't bothered to completely figure out this causes all offsets in range to be linked to, usually
      -- "big" means either it's a tag: that queues tagext:, or it's a tagext: already
      for i = tag_or_tagext_start_offset,(tag_or_tagext_end_offset - 1) do
        check("https://cohost.org/rc/tagged/" .. tag_or_tagext_tag_content .. "?refTimestamp=" .. tag_or_tagext_timestamp .. "&skipPosts=" .. tostring(i), true)
      end
    end
  elseif current_item_type == "post" then
    assert(do_debug)
    
    local username_base, postid_base = url:match("^https?://cohost%.org/(" .. USERNAME_RE .. ")/post/([0-9]+).*")
    if username_base and postid_base then
      username_post_type = username_base
      postid_post_type = postid_base
      if status_code ~= 404 then
        check('https://cohost.org/api/v1/trpc/posts.singlePost?batch=1&input={"0":{"handle":"' .. username_base .. '","postId":' .. postid_base .. '}}')
      end
    elseif url:match("^https://cohost%.org/api/v1/trpc/posts%.singlePost%?batch") then
      local json = json_decode(load_html())
      process_post(json[1]["result"]["data"]["post"], username_post_type, check, insane_url_extract)
    end
  elseif current_item_type == "userfix1" then
    if status_code == 200 then
      if url:match("^https?://cohost%.org/" .. USERNAME_RE .. "/?$") then
        -- Copied from the user handler
        local loader_state = json_decode(load_html():match('<script type="application/json" id="__COHOST_LOADER_STATE__">(.-)</script>'))
        local capitalized_handle = loader_state["project-page-view"]["project"]["handle"]
        
        if load_html():match('<h1 class="text%-xl font%-bold">this page is not viewable by logged%-out users</h1>')
          or load_html():match('<h1 class="text%-xl font%-bold">this page is private</h1>') then
          print_debug("User not publicly viewable")
        elseif capitalized_handle ~= current_user then
          assert(capitalized_handle:lower() == current_user:lower())
          discover_item("userfix1", capitalized_handle)
          print_debug("Cutting userfix1 short")
        else
          check_profile_posts_listing_batch(current_user, 0, true)
        end
      else
        local req_json_raw = url:match("^https://cohost%.org/api/v1/trpc/projects%.followingState,posts.profilePosts%?batch=1&input=(.+)")
        if req_json_raw then
          local resp_json = json_decode(load_html())
          local req_json = json_decode(urlparse.unescape(req_json_raw))
          local page = req_json["1"]["page"]
      
          local pagination = resp_json[2]["result"]["data"]["pagination"]
          assert(pagination["morePagesForward"])
          if #resp_json[2]["result"]["data"]["posts"] > 0 then
            assert(pagination["nextPage"] == page + 1)
            check_profile_posts_listing_batch(current_user, page + 1, true)
            discover_item("user", current_user .. "+" .. tostring(page + 1))
          end
        end
      end
    end
  elseif current_item_type == "userfix2" then
    -- Starting point for non-"+" users
    if url:match("^https://cohost%.org/[^/%?]+$") then
      assert(not current_item_value:match("%+"))
      if status_code == 200 and not cut_user_short then
        assert(current_user:match("^" .. USERNAME_RE .. "$"))
        check("https://" .. current_user:lower() .. ".cohost.org/")

        if not user_not_publicly_viewable then
          print_debug("User is publicly viewable")
          check_profile_posts_listing_singles(current_user, 0)
          check("https://cohost.org/api/v1/trpc/subscriptions.hasActiveSubscription?input=%7B%22projectHandle%22%3A%22" .. current_user .. "%22%7D")
          check("https://cohost.org/api/v1/trpc/projects.followingState?input=%7B%22projectHandle%22%3A%22" .. current_user .. "%22%7D")
          check("https://cohost.org/api/v1/trpc/projects.isReaderMuting?input=%7B%22projectHandle%22%3A%22" .. current_user .. "%22%7D")
          check("https://cohost.org/api/v1/trpc/projects.isReaderBlocking?input=%7B%22projectHandle%22%3A%22" .. current_user .. "%22%7D")
        end
      end
    end
    
    -- Starting point for "+" users
    if current_item_value:match("%+") and url:match("^https://cohost%.org/" .. USERNAME_RE .. "?page=[0-9]+$") then
      local page_number = current_item_value:match("%+([0-9]+)$")
      if status_code ~= 404 then
        check_profile_posts_listing_singles(current_user, tonumber(page_number))
      end
    end
    
    local posts_json = url:match("^https://cohost%.org/api/v1/trpc/posts%.profilePosts%?input=(.*)$")
    if posts_json then
      local req_json = CJSON.decode(urlparse.unescape(posts_json))
      local page = req_json["page"]
      assert(page == tonumber((current_item_value:match("%+([0-9]+)$"))) or 0)
      local resp_json = CJSON.decode(load_html())
      
      local pagination = resp_json["result"]["data"]["pagination"]
      assert(pagination["morePagesForward"]) -- Unclear what this is - I think sometimes the navigaion buttons disappear and this controls it, but can't reproduce that now
      if #resp_json["result"]["data"]["posts"] > 0 then
        assert(pagination["nextPage"] == page + 1)
        discover_item("userfix2", current_user .. "+" .. tostring(page + 1))
      end
      
      for _, post in pairs(resp_json["result"]["data"]["posts"]) do
        check(post["singlePostPageUrl"], true)
        check("https://cohost.org/api/v1/trpc/posts.singlePost?input=%7B%22handle%22%3A%22".. post["postingProject"]["handle"] .."%22%2C%22postId%22%3A".. post["postId"] .."%7D")
        print_debug("Checking post!")
        print_debug(CJSON.encode(post["blocks"]))
      end
    end
  end
  
  if current_item_type == "post" or current_item_type == "user" then
    if url:match("^https?://cdn%.iframe%.ly/api/iframely") then
      local json = json_decode(load_html())
      if not json["error"] and json["html"] then
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
  if status_code >= 300 and status_code <= 399 and (
      (url["url"]:match("^https://iframely%.net/api/thumbnail") or url["url"]:match("^https?://cohost%.org/api/v1/attachments/") or url["url"]:match("^https://cohost%.org/rc/attachment%-redirect/") or url["url"]:match("^https?://iframely%.net/"))
      or (redirects_level > 0 and redirects_level < 5)
    ) then
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
  
  if status_code >= 300 and status_code <= 399 and url["url"]:match("^https?://" .. USERNAME_RE .. "%.cohost%.org/tagged/") then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    local userm, tagm = newloc:match("^https?://cohost%.org/(" .. USERNAME_RE .. ")/tagged/(.+)")
    assert(userm:lower() == current_user:lower())
    discover_item("usertag", userm .. "/" .. tagm)
    return wget.actions.EXIT
  end
  
  if url["url"]:match("^https?://cohost%.org/api/v1/attachments/") or url["url"]:match("^https://cohost%.org/rc/attachment%-redirect/") then
    error("URL should have had a redirect on it")
  end
  
  
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
  if status_code ~= 200 and status_code ~= 404
    and not (url["url"]:match("^https?://cohost%.org/[^/%?]+$") and status_code == 404)
    and not (not url_is_essential and status_code == 404)
    and not (url["url"]:match("^https?://cdn%.iframe%.ly/") and status_code >= 400 and status_code <= 499) 
    and not (status_code == 404 and url["url"]:match("^https://" ..USERNAME_RE .. "%.cohost%.org/")) -- Spurious extractions by DCP of relative links on subdomains. Outside subdomains these are backfed as spurious users so this only happens here. Seeing how peripheral subdomains are, I don't think this will ever indicate a problem worth our notice.
    and not (status_code == 403 and user_not_publicly_viewable)
    and not (status_code == 207 and url["url"]:match("posts%.singlePost"))
    and not ((status_code == 403 or status_code == 500) and url["url"]:match("^https?://[a-z%-]+%.cohostcdn%.org/.*"))
    and not (status_code == 422 and url["url"]:match("^https?://proxy%-staging%.cohostcdn%.org/.*"))
    and not (status_code == 0   and err == "HOSTERR" and url["url"]:match("^https?://" .. USERNAME_RE .. "%.cohost%.org/") and current_item_type == "user" and #current_user > 63)
    and not (status_code == 414 and (current_item_type == "tag" or current_item_type == "tagext" or current_item_type == "usertag") and #current_item_value > 8000)
    then
    print("Server returned " .. http_stat.statcode .. " (" .. err .. "). Sleeping.\n")
    do_retry = true
  elseif string.match(url["url"], "^https?://cohost%.org/api/") and not string.match(url["url"], "^https?://cohost%.org/api/v1/attachments/") then
      local json = json_decode(read_file(http_stat["local_file"]))
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
    error("Failed to send binary")
  end
end

-- Taken verbatim from previous projects I've done'
local queue_list_to = function(list, key)
  assert(key)
  if do_debug then
    for item, _ in pairs(list) do
      assert(string.match(item, ":"))
      assert(not fun.iter(item):any(function(b) return b == "\0" end))
      print("Would have sent discovered item " .. item)
    end
  else
    local to_send = nil
    for item, _ in pairs(list) do
      assert(string.match(item, ":")) -- Message from EggplantN, #binnedtray (search "colon"?)
      assert(not fun.iter(item):any(function(b) return b == "\0" end))
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
  if (string.match(url["url"], "^https?://cohost%.org/") or string.match(url["url"], "^https?://[^%.]+%.cohost%.org/") or string.match(url["url"], "^https?://[^%.]+%.cohostcdn%.org/"))
          and http_stat["statcode"] ~= 200 and http_stat["statcode"] ~= 404
          and not (http_stat["statcode"] >= 300 and http_stat["statcode"] <= 399)
          and not (http_stat["statcode"] == 403 and user_not_publicly_viewable)
          and not (http_stat["statcode"] == 207 and url["url"]:match("posts%.singlePost"))
          and not ((http_stat["statcode"] == 403 or http_stat["statcode"] == 500) and url["url"]:match("^https?://[a-z%-]+%.cohostcdn%.org/.*"))
          and not (http_stat["statcode"] == 422 and url["url"]:match("^https?://proxy%-staging%.cohostcdn%.org/.*"))
          and not (http_stat["statcode"] == 414 and (current_item_type == "tag" or current_item_type == "tagext" or current_item_type == "usertag") and #current_item_value > 8000)
          then
    print_debug("Not WTW")
    return false
  elseif string.match(url["url"], "^https?://cohost%.org/api/") and not string.match(url["url"], "^https?://cohost%.org/api/v1/attachments/") then
    local json = json_decode(read_file(http_stat["local_file"]))
    if not json then
      error("Failed to parse as JSON the response from " .. url["url"] .. " : " .. read_file(http_stat["local_file"]))
    end
    if json["error"] then
      print_debug("Not WTW")
      return false
    end
  end
  return true
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if abortgrab == true then
    return wget.exits.IO_FAIL
  end
  return exit_status
end

