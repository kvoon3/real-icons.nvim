return function(test, eq, truth, with_modules)
  local icons = require("real-icons")
  local assets = require("real-icons.assets")
  local renderer = require("real-icons.render.placeholder")
  local cache = require("real-icons.cache")
  local fixture_root = vim.fn.getcwd() .. "/tests/fixtures"
  local function fixture_options()
    return {
      pack = "fixture",
      backend = "disabled",
      packs = { fixture = { type = "vscode", path = fixture_root, manifest = "theme.json" } },
    }
  end

  test("enabled integration errors remain visible and can be retried", function()
    local available = false
    local notifications = {}
    local notify = vim.notify
    vim.notify = function(message)
      notifications[#notifications + 1] = message
    end
    with_modules({
      ["real-icons.integrations.telescope"] = {
        setup = function()
          return available, available and nil or "dependency is not available"
        end,
      },
    }, {}, function()
      icons.setup({ pack = "builtin", backend = "disabled", integrations = { telescope = true } })
      eq(icons.integration_status().telescope.status, "error")
      truth(icons.integration_status().telescope.error:find("dependency", 1, true))
      truth(#notifications > 0, "failed setup must notify")
      available = true
      eq(icons.retry_integrations().telescope.status, "ready")
    end)
    vim.notify = notify
    local config = require("real-icons.config")
    local previous = config.options
    eq(pcall(config.setup, { integrations = { typo = true } }), false)
    eq(config.options, previous, "invalid settings preserve the previous configuration")
  end)

  test("cached picker items follow pack, colorscheme, and clear-cache changes", function()
    local send = vim.api.nvim_chan_send
    vim.api.nvim_chan_send = function() end
    icons.setup({
      pack = "first",
      backend = "kitty",
      packs = {
        first = { type = "simple", path = assets.dir(), file = "filetypes/lua.png" },
        second = { type = "simple", path = assets.dir(), file = "filetypes/typescript.png" },
      },
    })
    local adapter = require("real-icons.integrations.snacks_picker")
    local item = { file = "example.lua", dir = false }
    adapter.icon(item)
    eq(item._real_icons_segment.icon.pack, "first")
    truth(icons.use_pack("second", { notify = false }))
    adapter.icon(item)
    eq(item._real_icons_segment.icon.pack, "second")
    local hl = item._real_icons_segment.hl
    vim.api.nvim_set_hl(0, hl, {})
    vim.api.nvim_exec_autocmds("ColorScheme", { modeline = false })
    adapter.icon(item)
    truth(vim.api.nvim_get_hl(0, { name = hl }).fg, "colorscheme must recreate image highlighting")
    local old = item._real_icons_segment
    icons.clear_cache()
    adapter.icon(item)
    truth(item._real_icons_segment ~= old, "clear-cache must invalidate item segments")
    require("real-icons.backend.kitty").clear_uploaded()
    vim.api.nvim_chan_send = send
  end)

  test("one PNG can be uploaded at different cell widths", function()
    local backend = require("real-icons.backend.kitty")
    local send = vim.api.nvim_chan_send
    local writes = {}
    vim.api.nvim_chan_send = function(_, data)
      writes[#writes + 1] = data
    end
    backend.clear_uploaded()
    local icon = { asset = assets.file("filetypes", "lua") }
    local one = backend.upload(icon, { cols = 1, rows = 1 })
    local three = backend.upload(icon, { cols = 3, rows = 1 })
    truth(one ~= three, "different placements need different ids")
    eq(backend.upload(icon, { cols = 1, rows = 1 }), one, "same placement is reused")
    backend.clear_uploaded()
    vim.api.nvim_chan_send = send
    truth(table.concat(writes):find("c=3", 1, true))
  end)

  if vim.fn.executable("magick") == 1 then
    test("cold SVG rendering returns immediately and refreshes the same extmark", function()
      local send = vim.api.nvim_chan_send
      vim.api.nvim_chan_send = function() end
      local options = fixture_options()
      options.backend = "kitty"
      icons.setup(options)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "example.ts" })
      local segment = icons.segment("file", "example.ts", { is_dir = false })
      truth(segment.pending, "a cold conversion must be queued")
      eq(segment.width, options.size and options.size.cols or 2)
      local id = icons.render(bufnr, 0, 0, "file", "example.ts", { is_dir = false })
      eq(cache.status().pending, 1, "the same SVG is only queued once")
      truth(
        vim.wait(10000, function()
          return cache.status().pending == 0
        end, 10),
        "conversion timeout"
      )
      renderer.refresh()
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, renderer.ns, 0, -1, { details = true })
      eq(#marks, 1)
      eq(marks[1][1], id, "refresh preserves the extmark id")
      truth(marks[1][4].virt_text[1][2]:find("RealIconsImage", 1, true))
      vim.api.nvim_buf_delete(bufnr, { force = true })
      require("real-icons.backend.kitty").clear_uploaded()
      vim.api.nvim_chan_send = send
    end)

    test("cache identities include the source and damaged files are rebuilt", function()
      icons.setup({ pack = "builtin", backend = "disabled" })
      local a = { pack = "source-test", key = "same", source = fixture_root .. "/red.svg" }
      local b = { pack = "source-test", key = "same", source = fixture_root .. "/blue.svg" }
      truth(cache.target(a) ~= cache.target(b))
      local target = assert(cache.ensure(a))
      vim.fn.writefile({ "corrupt" }, target)
      local done, error_message
      eq(
        cache.ensure_async(a, {}, function(path, err)
          done, error_message = path, err
        end),
        nil
      )
      truth(vim.wait(10000, function()
        return done ~= nil or error_message ~= nil
      end, 10))
      truth(done, error_message)
      truth(vim.uv.fs_stat(target).size > 8)
    end)

    test("a PNG larger than the icon box is resized, a smaller one is reused", function()
      -- Terminals downsample with a coarse GPU filter, so a source larger than
      -- the configured box loses the thin strokes icon themes rely on. Anything
      -- at or below the box is already fine and must not require ImageMagick.
      local root = vim.fn.tempname()
      vim.fn.mkdir(root .. "/icons", "p")
      vim.fn.writefile({
        vim.json.encode({
          iconDefinitions = {
            big = { iconPath = "./icons/big.png" },
            small = { iconPath = "./icons/small.png" },
          },
          file = "small",
          fileExtensions = { big = "big", small = "small" },
        }),
      }, root .. "/theme.json")

      local function write_png(path, width, height)
        local svg = string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d"><rect width="%d" height="%d" fill="#89b4fa"/></svg>', width, height, width, height)
        vim.fn.writefile({ svg }, path .. ".svg")
        vim.fn.system({ "rsvg-convert", "--output", path, path .. ".svg" })
        vim.fn.delete(path .. ".svg")
      end

      write_png(root .. "/icons/big.png", 128, 128)
      write_png(root .. "/icons/small.png", 48, 48)

      icons.setup({
        pack = "png-size-" .. vim.fn.getpid(),
        backend = "disabled",
        packs = { ["png-size-" .. vim.fn.getpid()] = { type = "vscode", path = root, manifest = "theme.json" } },
        size = { pixels = 48 },
      })

      local small = icons.resolve("file", "x.small", {})
      local small_path = small.source or small.asset
      eq(cache.ensure(small, { size = { pixels = 48 } }), small_path, "a fitting PNG is reused")

      local big = icons.resolve("file", "x.big", {})
      local big_path = big.source or big.asset
      local resized = cache.ensure(big, { size = { pixels = 48 } })
      truth(resized, "an oversized PNG must be converted")
      truth(resized ~= big_path, "an oversized PNG must not be reused as-is")
      eq(vim.fn.getfsize(resized) > 8, true, "the converted PNG exists")

      vim.fn.delete(root, "rf")
    end)

    test("SVG sources convert through rsvg-convert when ImageMagick is absent", function()
      -- rsvg-convert renders straight to the target size, which is sharper than
      -- rasterising with ImageMagick and downsampling afterwards. It is also the
      -- only converter available without ImageMagick installed.
      if vim.fn.executable("rsvg-convert") ~= 1 then
        return
      end

      local root = vim.fn.tempname()
      vim.fn.mkdir(root .. "/icons", "p")
      vim.fn.writefile({
        vim.json.encode({
          iconDefinitions = { _file = { iconPath = "./icons/lua.svg" } },
          file = "_file",
          fileExtensions = { lua = "_file" },
        }),
      }, root .. "/theme.json")
      vim.fn.writefile({
        '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><circle cx="8" cy="8" r="6"/></svg>',
      }, root .. "/icons/lua.svg")

      icons.setup({
        pack = "rsvg-probe",
        backend = "disabled",
        packs = { ["rsvg-probe"] = { type = "vscode", path = root, manifest = "theme.json" } },
        size = { pixels = 48, trim = false },
      })

      local icon = icons.resolve("file", "x.lua", {})
      truth((icon.source or icon.asset):match("%.svg$"), "the source is an SVG")
      local converted, err = cache.ensure(icon, { size = { pixels = 48, trim = false } })
      truth(converted, err or "SVG conversion must succeed without ImageMagick")
      truth(converted ~= (icon.source or icon.asset), "the SVG is converted, not reused")
      truth(vim.fn.getfsize(converted) > 8, "the converted PNG exists")

      vim.fn.delete(root, "rf")
    end)

    test("SVG sources keep their aspect ratio inside the icon box", function()
      -- ImageMagick's resize fits the source inside the box and centres it. The
      -- rsvg-convert path has to match that: rendering a 2:1 view box straight
      -- into a square box would stretch it and misalign it against
      -- ImageMagick-produced caches.
      if vim.fn.executable("rsvg-convert") ~= 1 then
        return
      end

      local root = vim.fn.tempname()
      vim.fn.mkdir(root .. "/icons", "p")
      vim.fn.writefile({
        vim.json.encode({
          iconDefinitions = { _file = { iconPath = "./icons/wide.svg" } },
          file = "_file",
          fileExtensions = { wide = "_file" },
        }),
      }, root .. "/theme.json")
      vim.fn.writefile({
        '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="16" viewBox="0 0 32 16">',
        '<rect x="0" y="0" width="32" height="16" fill="#00ff00"/></svg>',
      }, root .. "/icons/wide.svg")

      icons.setup({
        pack = "aspect-probe",
        backend = "disabled",
        packs = { ["aspect-probe"] = { type = "vscode", path = root, manifest = "theme.json" } },
        size = { pixels = 48, trim = false },
      })

      local icon = icons.resolve("file", "x.wide", {})
      local converted, err = cache.ensure(icon, { size = { pixels = 48, trim = false } })
      truth(converted, err)

      -- A 2:1 source in a 48px box occupies 48x24 centred at y = 12.
      local box = vim.fn.system({ "magick", converted, "-format", "%@", "info:" })
      eq(box, "48x24+0+12", "the source is fitted and centred, not stretched")

      vim.fn.delete(root, "rf")
    end)

    test("a converter that cannot render SVG is reported, not treated as working", function()
      -- An ImageMagick built without librsvg is on PATH but falls back to its
      -- internal MSVG renderer, which rejects the arc syntax icon themes use.
      -- Checking the binary alone marks the setup healthy while most of a pack
      -- silently falls back to glyphs.
      if vim.fn.executable("rsvg-convert") == 1 then
        return
      end
      if vim.fn.executable("magick") ~= 1 then
        return
      end

      eq(cache.converter(), "magick")
      truth(cache.converter_works(), "this ImageMagick renders SVG and must be accepted")
    end)
  end
end
