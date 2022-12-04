local bump = require "lib/bump"
local class = require "lib/middleclass"
local vector = require "lib/vector"
local baton = require "lib/baton"

if os.getenv("LOCAL_LUA_DEBUGGER_VSCODE") == "1" then
  require("lldebugger").start()
end

-- game variables
local player_speed = 300-- 400
local beast_speed = 100 -- 150
local grid_size = 32
local players = {}
local blocks = {}
local enemies = {}
local num_lives
local level = 1
local player_colors = {
  {140/255, 60/255, 140/255},
  {62/255, 98/255, 187/255},
  {62/255, 187/255, 66/255},
  {187/255, 166/255, 62/255},
  {62/255, 187/255, 183/255}
}

-- generic drawable sprite (for prototyping, just a filled rect)
local Sprite = class('Sprite')

function Sprite:draw()
  love.graphics.setColor(self.color)
  love.graphics.rectangle("fill", self.x, self.y, self.width, self.height)
end

function Sprite:push(other, x, y)
  local actualX, actualY, cols, len = world:check(self, x, y, function(item, other)
    return "cross"
  end)
  
  local success = true
  for i=1, len do
    local col = cols[i]
    if col.other ~= other then
      local other_x = col.other.x
      local other_y = col.other.y
      
      if col.normal.x == -1 then
        other_x = other_x + grid_size -- self.x + self.width
      elseif col.normal.x == 1 then
        other_x = other_x - grid_size -- self.x - col.other.width
      end
      
      if col.normal.y == -1 then
        other_y = other_y + grid_size -- self.y + self.height
      elseif col.normal.y == 1 then
        other_y = other_y - grid_size -- self.y - col.other.height
      end
      
      if not col.other:push(self, other_x, other_y) then
        success = false
      end
    end
  end

  if success then
    actualX, actualY = world:move(self, x, y, function(item, other)
      return "cross"
    end) 
    self.x = actualX
    self.y = actualY 
  end
  return success
end

-- Playable Player
local Player = class('Player', Sprite)
function Player:initialize(x, y, input, color)
  self.input = input
  self.color = color
  self.width = grid_size
  self.height = grid_size
  self.x = x
  self.y = y
  self.pulled_block = nil
  Sprite.initialize(self)
end

function Player:update(dt)
  self.input:update(dt)
  local x = self.x
  local y = self.y
  local dx, dy = self.input:get('move')
  
  -- user is moving
  if dx ~= 0 or dy ~= 0 then
    x = x + (dx * player_speed * dt)
    y = y + (dy * player_speed * dt)
  end

  -- user is moving slower in this dimension
  -- so snap to the grid
  if math.abs(dx) < 0.5 then
    x = snap(x)
  end
  if math.abs(dy) < 0.5 then
    y = snap(y)
  end

  -- pull blocks if the pull button is pressed
  local pulled_block, pull_dest_x, pull_dest_y
  if self.input:down('pull') and (x ~= self.x or y ~= self.y) then
    local is_horiz = math.abs(dx) > math.abs(dy)
    local behind_x
    local behind_y
    if is_horiz then
      if dx > 0 then
        behind_x = self.x - 1
      else
        behind_x = self.x + grid_size + 1
      end
      behind_y = self.y + grid_size / 2
    else
      if dy > 0 then
        behind_y = self.y - 1
      else
        behind_y = self.y + grid_size + 1
      end
      behind_x = self.x + grid_size / 2
    end

    local items, items_len = world:queryPoint(behind_x, behind_y, function(item)
      return item.class.name == 'Block' -- reference to the class Block doesn't match!
    end)

    pulled_block = items[1]
    if pulled_block then
      if is_horiz then
        pull_dest_x = pulled_block.x + (x - self.x) -- recalc dx due to snapping above
        pull_dest_y = pulled_block.y
      else
        pull_dest_y = pulled_block.y + (y - self.y) -- recalc dy due to snapping above
        pull_dest_x = pulled_block.x
      end
    end
  end

  self:push(nil, x, y)

  -- have to pull block *after* doing the move/push, so there's room for it
  if pulled_block then
    local actualX, actualY, cols, len = world:move(pulled_block, pull_dest_x, pull_dest_y, function(item, other)
      return "slide"
    end)
    pulled_block.x = actualX
    pulled_block.y = actualY
    self.pulled_block = pulled_block
  end

  -- we just *stopped* pulling a block
  if self.pulled_block and not pulled_block then
    local block = self.pulled_block
    --local actualX, actualY, cols, len = 
    world:update(block, snap(block.x), snap(block.y))--, function(item, other)
    --   return "slide"
    -- end)
    print(block.y, snap(block.y), actualY) 
    block.x = snap(block.x)--actualX
    block.y = snap(block.y)-- actualY
    self.pulled_block = nil
  end
end

function Player:dieAndRespawn()
  num_lives = num_lives - 1
  if num_lives == 0 then
    love.event.quit()
  end

  local x, y = findEmptyGridSquare()
  
  world:update(self, x, y)
  self.x = x
  self.y = y
end

-- enemy
local Enemy = class('Enemy', Sprite)
function Enemy:initialize(x, y)
  self.color = {140/255, 60/255, 60/255}
  self.width = grid_size
  self.height = grid_size
  self.x = x
  self.y = y
  Sprite.initialize(self)
end

function Enemy:update(dt)
  local nearest_player = nil
  local nearest_dist = 200 * grid_size
  for i = 1, #players do
    local dx = math.abs(players[i].x - self.x)
    local dy = math.abs(players[i].y - self.y)
    -- simple "nearest" formulation (not accurate, I know)
    local dist = dx + dy
    if dist < nearest_dist then
      nearest_player = players[i]
      nearest_dist = dist
    end
  end

  local dir = vector(nearest_player.x - self.x, nearest_player.y - self.y)
  dir:normalizeInplace()
  dir = dir * beast_speed * dt
  local x = self.x + dir.x
  local y = self.y + dir.y

  -- often the beasts get *super* close to going through a hole, but not quite
  -- we can fix this by a slight adjustment: if either dimension is super-close
  -- to being on a grid line, adjust it so it is on the grid line
  local x_offset = x % grid_size
  if math.abs(x_offset) < 2 then
    if x_offset > 0 and dir.x < 0 then
      x = x - x_offset
    else
      x = x + x_offset
    end
  end

  local y_offset = y % grid_size
  if math.abs(y_offset) < 2 then
    if y_offset > 0 and dir.y < 0 then
      y = y - y_offset
    else
      y = y + y_offset
    end
  end

  local actualX, actualY, cols, len = world:move(self, x, y, function(item, other)
    return "slide"
  end)

  for i=1, len do
    local col = cols[i]
    if col.other:isInstanceOf(Player) then
      col.other:dieAndRespawn()
    end
  end

  self.x = actualX
  self.y = actualY
end

function Enemy:push(other, x, y)
  -- *check* if there would be a collision
  local actualX, actualY, cols, len = world:check(self, x, y, function(item, other)
    return "cross"
  end)
  
  -- we get squished if there would've been a collision
  -- TODO: we should probably check that it's not a player on the other side...
  if #cols ~= 0 then
    local ix
    for i=1, #enemies do
      if enemies[i] == self then
        ix = i
      end
    end
    table.remove(enemies, ix)
    world:remove(self)

    if #enemies == 0 then
      level = level + 1
      spawnEnemies()
    end
  end
  return false
end

-- movable block
local Block = class('Block', Sprite)
function Block:initialize(x, y)
  self.color = {200/255, 200/255, 200/255}
  self.width = grid_size
  self.height = grid_size
  self.x = x
  self.y = y
  Sprite.initialize(self)
end

-- helper functions
function addSprite(spr)
  world:add(spr, spr.x, spr.y, spr.width, spr.height)
end

function generateBlocks()
  local win_width = love.graphics.getWidth()
  local win_height = love.graphics.getHeight()
  local num_blocks_x = win_width / grid_size
  local num_blocks_y = win_height / grid_size
  
  local block
  local block_ix = 1
  for y = 1, num_blocks_y do
    for x = 1, num_blocks_x do
      -- avoid creating blocks at 1,1 or 1,2, so they don't overlap w/ the players
      if x > 1 or y > 2 then
        if math.random(6) == 1 then
          block = Block:new((x - 1) * grid_size, (y - 1) * grid_size)
          table.insert(blocks, block)
          addSprite(block)
        end
      end
    end
  end
end

function spawnEnemies()
  local num_enemies = level * 2 + 2
  for i = 1, num_enemies do
    local x, y = findEmptyGridSquare()
    enemy = Enemy:new(x, y)
    table.insert(enemies, enemy)
    addSprite(enemy)
  end
end

function findEmptyGridSquare()
  -- TODO: store the *initial* num_blocks x/y and use that always
  local win_width = love.graphics.getWidth()
  local win_height = love.graphics.getHeight()
  local num_blocks_x = win_width / grid_size
  local num_blocks_y = win_height / grid_size
  
  local x, y, items, len_items
  x = math.random(num_blocks_x) * 32
  y = math.random(num_blocks_y) * 32
  items, len_items = world:queryRect(x, y, grid_size, grid_size)

  -- TODO: fix this DRY; I tried to do a do-while, but it failed
  while (len_items > 0)
  do
    x = math.random(num_blocks_x) * 32
    y = math.random(num_blocks_y) * 32
    items, len_items = world:queryRect(x, y, grid_size, grid_size)
  end
  return x, y
end

function snap(val)
  local offset = val % grid_size
  if offset < (grid_size / 2) then
    val = val - offset
  else
    val = val + (grid_size - offset)
  end
  return val
end

-- game callbacks
function love.load()
  local joysticks = love.joystick.getJoysticks()
  local num_players = #joysticks
  if num_players == 0 then
    num_players = 1 -- if there are no joysticks, fallback to one keyboard/mouse player
  end

  num_lives = num_players * 2

  for i=1, num_players do
    table.insert(players, Player:new(0, (i-1) * grid_size, baton.new({
      controls = {
        move_left = {'key:a', 'axis:leftx-', 'button:dpleft'},
        move_right = {'key:d', 'axis:leftx+', 'button:dpright'},
        move_up = {'key:w', 'axis:lefty-', 'button:dpup'},
        move_down = {'key:s', 'axis:lefty+', 'button:dpdown'},
        pull = {'key:space', 'button:a'},
      },
      pairs = {
        move = {'move_left', 'move_right', 'move_up', 'move_down'},
      },
      deadzone = 0.2,
      squareDeadzone = true, -- helps w/ player grid snapping when transitioning from diagonal to vert/horiz movement
      joystick = joysticks[i]
    }), player_colors[i]))
  end

  -- nearest neightbor & full-screen
  love.graphics.setDefaultFilter( 'nearest', 'nearest' )
  love.window.setFullscreen(true)
  love.mouse.setVisible(false)
  love.graphics.setBackgroundColor({150/255, 150/255, 150/255})
  
  -- prepare simple AABB collision world w/ cell size
  world = bump.newWorld(64)
  for i = 1, #players do
    addSprite(players[i])
  end
  
  generateBlocks()
  spawnEnemies()
end

function love.update(dt)
  for i = 1, #players do
    players[i]:update(dt)
  end
  for i = 1, #enemies do
    enemies[i]:update(dt)
  end
end

function love.draw()
  for i = 1, #players do
    players[i]:draw()
  end
  
  for i = 1, #blocks do
    blocks[i]:draw()
  end
  
  for i = 1, #enemies do
    local enemy = enemies[i]
    enemy:draw()
  end
end

function love.keypressed(k)
   if k == 'escape' then
      love.event.quit()
   end
end

