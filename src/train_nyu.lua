require 'rnn'
require 'model.gridLSTM_rnn'
require 'optim'
require 'util.SymmetricTable'
require 'image'


cmd = torch.CmdLine()
cmd:option('-gpuid',0,'which gpu to use. -1 = use CPU')
cmd:option('-seed',123,'torch manual random number generator seed')

-- optimization
cmd:option('-learning_rate',0.001, ' learning rate')
cmd:option('-learning_rate_decay',1,'learning rate decay')
cmd:option('-decay_rate',0.95,'decay rate for rmsprop')

opt = cmd:parse(arg)
torch.manualSeed(opt.seed)
nngraph.setDebug(false)

-- hyper-parameters 
p_size = 1
input_size_x = 32--36
input_size_y = 25--27
n_labels = 1
input_k = p_size * p_size * 3
rnn_size = 20
hiddenLayer = 40
output_size = 9
nIndex = 10
n_layers = 1
dropout = 0
should_tie_weights = 0
lr = opt.learning_rate
length = input_size_x * input_size_y
batch_size = 1
rho = length -- sequence length
load = false
img_x = 36
img_y = 27



local nyu = require 'data.nyu'

local trainset = nyu.traindataset
local testset = nyu.testdataset


print(trainset.size) -- to retrieve the size
print(testset.size) -- to retrieve the size

-- initialize cunn/cutorch for training on the GPU and fall back to CPU gracefully
if opt.gpuid >= 0 then
    local ok, cunn = pcall(require, 'cunn')
    local ok2, cutorch = pcall(require, 'cutorch')
    if not ok then print('package cunn not found!') end
    if not ok2 then print('package cutorch not found!') end
    if ok and ok2 then
        print('using CUDA on GPU ' .. opt.gpuid .. '...')
        cutorch.setDevice(opt.gpuid + 1) -- note +1 to make it 0 indexed! sigh lua
        cutorch.manualSeed(opt.seed)
    else
        print('If cutorch and cunn are installed, your CUDA toolkit may be improperly configured.')
        print('Check your CUDA toolkit installation, rebuild cutorch and cunn, and try again.')
        print('Falling back on CPU mode')
        opt.gpuid = -1 -- overwrite user setting
    end
end

zeroTensor = torch.Tensor()
if opt.gpuid >= 0 then 
  zeroTensor = torch.CudaTensor()
end

--------------------------------------------------------------
--      GridLSTM
--------------------------------------------------------------

-- Preprocessing of building blocks
local input = nn.ConcatTable()
input:add(nn.Linear(input_k, rnn_size))
input:add(nn.Linear(input_k, rnn_size))

local connect = nn.ParallelTable()
connect:add(nn.Linear(rnn_size, input_k))
connect:add(nn.Linear(rnn_size, input_k))

local connect_hidden = nn.ConcatTable()
connect_hidden:add(nn.Linear(rnn_size, rnn_size))
connect_hidden:add(nn.Linear(rnn_size, rnn_size))

local hidden_relu = nn.ParallelTable()
hidden_relu:add(nn.ReLU())
hidden_relu:add(nn.ReLU())

local hidden_relu_2 = nn.ParallelTable()
hidden_relu_2:add(nn.ReLU())
hidden_relu_2:add(nn.ReLU())

local template = nn.Sequential()
template:add(input)
template:add(nn.GridLSTM(input_size_x, input_size_y, rnn_size, rho, should_tie_weights, zeroTensor))
--template:add(nn.SelectTable(2))
--template:add(nn.Linear(rnn_size, input_k))
--template:add(nn.ReLU())


--template:add(connect)

local template_hidden = nn.Sequential()
template_hidden:add(nn.GridLSTM(input_size_x, input_size_y, rnn_size, rho, should_tie_weights, zeroTensor))
--template_hidden:add(nn.SelectTable(2))
--template_hidden:add(nn.Linear(rnn_size, input_k))
--template_hidden:add(nn.ReLU())
--
local template_final = nn.Sequential()
template_final:add(nn.GridLSTM(input_size_x, input_size_y, rnn_size, rho, should_tie_weights, zeroTensor))
template_final:add(nn.JoinTable(1,1))
--template_final:add(nn.SelectTable(2))


----- Create Modules
local grid_1 = template
local grid_2 = template_hidden -- template_hidden -- Top-Right Corner
local grid_3 = grid_2:clone()-- Bottom-Left Corner
local grid_4 = template_final -- Bottom-Right Corner

--- Reset clones
--grid_2:reset()
grid_3:reset()
--grid_4:reset()

--- Build GridLSTM 4 layers that process the data from different corners
local Seq_1 = nn.Sequencer(grid_1)   -- Top-Left Corner
local Seq_2 = nn.Sequencer(grid_2)   -- Top-Right Corner
local Seq_3 = nn.Sequencer(grid_3)   -- Bottom-Left Corner
local Seq_4 = nn.Sequencer(grid_4)   -- Bottom-Right Corner

--- grid_1 Top-Left Corner Stays the same
local SeqCorner_1  = Seq_1

--- grid_2 Top-Right Corner
local SeqCorner_2 = nn.Sequential()
SeqCorner_2:add(nn.SymmetricTable(input_size_x, input_size_y))   -- Symmetrify
SeqCorner_2:add(Seq_2)
SeqCorner_2:add(nn.SymmetricTable(input_size_x, input_size_y))   -- --UnSymmetrify

--- grid_3 Bottom-Left Corner
local SeqCorner_3 = nn.Sequential()
SeqCorner_3:add(nn.SymmetricTable(input_size_x, input_size_y))   -- Symmetrify
SeqCorner_3:add(nn.ReverseTable())     -- Reverse
SeqCorner_3:add(Seq_3)
SeqCorner_3:add(nn.ReverseTable())     -- Unreverse
SeqCorner_3:add(nn.SymmetricTable(input_size_x, input_size_y))   -- --UnSymmetrify

--- grid_4 Bottom-Right Corner
local SeqCorner_4 = nn.Sequential()
SeqCorner_4:add(nn.ReverseTable())     -- Reverse
SeqCorner_4:add(Seq_4)
SeqCorner_4:add(nn.ReverseTable())     -- Unreverse

local finalLayer = nn.Sequential()
--finalLayer:add(nn.JoinTable(1,1))
template_final:add(nn.Linear(2*rnn_size, 2048))
finalLayer:add(nn.ReLU())
template_final:add(nn.Linear(2048, n_labels*p_size*p_size))
finalLayer:add(nn.ReLU())
finalLayer:add(nn.Reshape(p_size*p_size, n_labels))
finalLayer:add(nn.SplitTable(2, p_size*p_size))

--- Concat everything together
--local concat = nn.ConcatTable()
--concat:add(SeqCorner_1):add(SeqCorner_2):add(SeqCorner_3):add(SeqCorner_4)

--- Init Merger
local merger = nn.Sequencer(nn.CAddTable(1,1))  

--- Final Merge of for concurrent layers
local gridLSTM = nn.Sequential()
--gridLSTM:add(concat)
--gridLSTM:add(nn.ZipTable())
--gridLSTM:add(merger)

gridLSTM:add(SeqCorner_1)
gridLSTM:add(SeqCorner_2)
gridLSTM:add(SeqCorner_3)
gridLSTM:add(SeqCorner_4)
gridLSTM:add(nn.Sequencer(finalLayer))
-- internally, rnn will be wrapped into a Recursor to make it an --AbstractRecurrent instance.


local model = gridLSTM
if load then model = torch.load('gridlstm.model') end 
--model:add(nn.JoinTable(1,1))
--model:add(nn.Linear(2*rnn_size*length, hiddenLayer))
--model:add(nn.ReLU())
--model:add(nn.Linear(hiddenLayer, 10))
--model:add(nn.LogSoftMax())

--print(model)

-- build criterion
--crit = nn.ParallelCriterion()
--for i=1,p_size*p_size do
--  crit:add(nn.ClassNLLCriterion())
--end
crit = nn.ParallelCriterion()
crit:add(nn.AbsCriterion())
criterion = nn.SequencerCriterion(crit)

-- this matrix records the current confusion across classes
classes = {'1','2','3','4','5','6','7','8','9','10'}
confusion = optim.ConfusionMatrix(classes)
--testLogger = optim.Logger(paths.concat(opt.save, 'test.log'))

if opt.gpuid >= 0 then
  model:cuda()
  criterion:cuda()
end

-- Load Batch
current_batch = 0
function next_batch(b_size)

   batch_x = torch.Tensor(b_size, 3, img_x*img_y)
   batch_y = torch.Tensor(b_size, 1, img_x*img_y)
   for i = 1, b_size do

       local x = trainset.x[(current_batch*(b_size)+i)%trainset.size+1] --image.translate(ex.x, torch.random(0, 4), torch.random(0, 4)) -- the input (a 28x28 ByteTensor)
       local y = trainset.y[(current_batch*(b_size)+i)%trainset.size+1]
       batch_x[i] = x
       batch_y[i] = y+1
   end
   
   batch_x = prepro(batch_x)
   batch_y = prepro(batch_y)

   local inputs = {}
   local outputs = {}
   local k = 1

   for y = 1, input_size_y do 
      for x = 1, input_size_x do
        k = p_size*(y-1)*input_size_x + p_size*(x-1) + 1

        patch_x  = {}
        patch_y  = {}
        -- Get Patch with p_size
        for x_p = 0, p_size-1 do 
           for y_p = 0, p_size-1 do

             table.insert(patch_x, batch_x[k+y_p*p_size+x_p])
             table.insert(patch_y, batch_y[k+y_p*p_size+x_p]) -- :squeeze()
           end 
         end 
        --table.insert(inputs, nn.JoinTable(2):forward{batch_x[k], batch_x[k+1], batch_x[k+input_size_x], batch_x[k+input_size_x+1]})
        table.insert(inputs, nn.JoinTable(2):forward{unpack(patch_x)})
        table.insert(outputs, patch_y)
      
      end
   end

   current_batch = current_batch + 1
    if opt.gpuid >= 0 then
      for i = 1, length do 
          inputs[i] = inputs[i]:cuda()
          outputs[i] = outputs[i]
      end
    end

   return inputs, outputs
end


-- preprocessing helper function
function prepro(x)

   x = x:permute(3,1,2):contiguous() -- swap the axes for faster indexing
   if opt.gpuid >= 0 then -- ship the input arrays to GPU
        -- have to convert to float because integers can't be cuda()'d
        x = x:float():cuda()
   end

   return x
end



-- test function
function testing(dataset)
   -- local vars
   local time = sys.clock()

   -- test over given dataset
   local c_batch = 1
   b_size = batch_size
   print('<trainer> on testing Set:')
   for t = 1,dataset.size,b_size do
      if(c_batch*b_size> 1000) then break end
      batch_x = torch.Tensor(b_size, 3, img_x*img_y)
      batch_y = torch.Tensor(b_size, 1, img_x*img_y)
      for i = 1, b_size do
          if(c_batch*b_size+i> dataset.size) then break end

          local x = dataset.x[c_batch*(b_size)+i]
          local y = dataset.y[c_batch*(b_size)+i]
   
          batch_x[i] = x
          batch_y[i] = y+1
      end
      c_batch = c_batch +1
      batch_x = prepro(batch_x)
      batch_y = prepro(batch_y)
   
      local inputs = {}
      local outputs = {}
      local k = 1
      for y = 1, input_size_y do 
         for x = 1, input_size_x do
            k = p_size*(y-1)*input_size_x + p_size*(x-1) + 1

            patch_x  = {}
            patch_y  = {}
            -- Get Patch with p_size
            for x_p = 0, p_size-1 do 
               for y_p = 0, p_size-1 do 
                 table.insert(patch_x, batch_x[k+y_p*p_size+x_p])
                 table.insert(patch_y, batch_y[k+y_p*p_size+x_p]) --:squeeze()
               end 
             end 
            table.insert(inputs, nn.JoinTable(2):forward{unpack(patch_x)})
            table.insert(outputs, patch_y)
          end
      end

      if opt.gpuid >= 0 then
        for i = 1, length do 
          inputs[i] = inputs[i]:cuda()
        end
      end

      --for i = 1, length do 
      --   table.insert(inputs, batch_x[i])
      --end

      -- test samples
      local preds = model:forward(inputs)
      -- confusion:
      for i = 1, batch_size do
        --write log10 error detector

        --confusion:add(preds[i], outputs[i])
      end
   end

   -- timing
   time = sys.clock() - time
   time = time / (c_batch * b_size)
   print("<trainer> time to test 1 sample = " .. (time*1000) .. 'ms')

   -- print confusion matrix
   print(confusion)
   print('% mean class accuracy (test set)'..confusion.totalValid * 100)
   confusion:zero()
end

x_weights, dl_dx = model:getParameters()

feval = function(x_new)
    -- copy the weight if are changed
    if x_weights ~= x_new then
        x_weights:copy(x_new)
    end
    -- select a training batch
    local inputs, targets = next_batch(batch_size)
    -- reset gradients (gradients are always accumulated, to accommodate
    -- batch methods)
    dl_dx:zero()

    -- evaluate the loss function and its derivative with respect to x_weights, given a mini batch
    local prediction = model:forward(inputs)
    --print(prediction)
    --print(targets)
    local loss_x = criterion:forward(prediction, targets)
    model:backward(inputs, criterion:backward(prediction, targets))

    return loss_x, dl_dx
end

adam_params = {
   learningRate = lr,
   --learningRateDecay = 1e-4,
   --weightDecay = 0,
   --momentum = 0
}

local optim_state = {learningRate = opt.learning_rate, alpha = opt.decay_rate}
-- training
local iteration = 1
local i = 1
while true do

    _, fs = optim.adam(feval,x_weights,adam_params)

   print(string.format("Iteration %d ; NLL err = %f ", iteration, fs[1]))
      
   -- 4. update
   if(i==0) then 
      torch.save('gridlstm.model', model)
      testing(testset)
      --print('error for iteration ' .. sgd_params.evalCounter  .. ' is ' .. fs[1] / rho)
   end
   i = (i+1)%66
   
   iteration = iteration + 1
end
