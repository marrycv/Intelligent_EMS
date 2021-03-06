% DESCRIPTION:
% Energy Management System based on Machine Learning theory (reinforcment
% learning) for a DC grid. The main source of power is a fuel-cell and a
% battery is connected to the grid to supply fast load changes (the slow
% dynamics of the FC cannot supply fast load changes).
% The aim of machine learning is to make the grid more efficient (by
% minimizing the losses in converters and battery for example) and to
% increase lifecycle of the system by reducing stress on components.
%
% Goal 1: Ensure the power supply at any time (done by the hardware, not
% related to ML)
% Goal 2: Maintain the State of Charge of the battery in [SOCmin;SOCmax].
% Goal 3: Minimize fuel consumption of the grid.
% Goal 3bis: Minimize stress on conponents (increase lifetime)

% NOTE:
% For reusability, all the script is written in p.u.
% The conversion to international system values is done in a dedicated
% block of the Simulink model.

% INPUT:
% Structure containing the parameters for simulation following this
% pattern:
%             simParam = struct(...
%                 'model','DC_grid_V2',...
%                 'maxEpi',1000,...
%                 'totalTime',1800,...
%                 'iterationTime',2.6,...
%                 'learnRate',0.1,...
%                 'epsilon',2,...
%                 'epsilonDecay',0.99994,...
%                 'discount',0.999,...
%                 'successRate',1,...
%                 'weightSOC',1,...
%                 'weightP_FC',1,...
%                 'weightP_batt',2,...
%                 'weightSteady',1,...
%                 'parentFolder','3_august',...
%                 'subFolder','Constant_command_forced'...
%                 );

% STATUS:
% The function is working fine (no harmful errors detected)
% Two knowed points to improve or fix:
% - Avoid the use of global variables and set the parallel computing
%   framework
% - Fix the issue of the plotting during the 10 first seconds (see plot for
%   details)
% - The function is sometimes crashing at the 4th episode because of the
%   realistic load in Simulink. Solved by restarting Matlab, or by fixing
%   the problem (not done yet)

function QlearningEMS(simParam)

global inputsFromWS %...Should find solution to avoid it...
% Having a global variable is not very good practice, but it helped here to
% gain time...
% Global variable does not allow parallel computing, which is a big
% limitation for this script.


% Create a diary to track only the Simulink errors (the script is supposed
% to work properly)
diary
diary off

% #########################################################################
% ################                STATES             ######################
% #########################################################################

% The states can be weighted from the calling script. If weight equals to
% zero, the state should not be considered.

% Initialize all the states as if they were not used:
% The suffix _Q is added to emphasize that this is the state used in the
% Q-learning calculation
Time_steady_Q = [0];
P_batt_Q = [0];
P_FC_Q = [0];
% SOC_Q = [0];

% Booleans for rewarding (initialized to false)
isTimeSteadyConsidered = 0;
isP_battConsidered = 0;
isP_FCConsidered = 0;

if simParam.weightSteady ~= 0
    Time_steady_Q = [5 8]; % For how long is the input the same ?
    isTimeSteadyConsidered = 1;
    probability_Forced_Constant_Sequence = 0.15; % Help to learn taking more constant actions during decay phase [0;1]
else
    probability_Forced_Constant_Sequence = 0;
end

if simParam.weightP_batt ~= 0
    P_batt_Q =  [-1 -0.8 -0.55 -0.25 0.25 0.55 0.8 1];
    isP_battConsidered = 1;
end

if simParam.weightP_FC ~= 0
    P_FC_Q = [0.7 0.9]; % Centered on 0.8 mean P_FC < 0.8 = good else bad
    isP_FCConsidered = 1;
end

if simParam.weightSOC ~= 0
    SOC_Q = single(linspace(0.4,1,13)); % Battery state of charge
    % The SOC is always considered
else
    error('Error: SOC must be controlled, weight cannot be equal to 0');
end


% Generate a state list
% 3 Column matrix of all possible combinations of the discretized state.
Q_states=zeros(length(Time_steady_Q)*length(P_batt_Q)*length(P_FC_Q)*length(SOC_Q),4,'single');
% This part doesn't need to be optimized for simulation time (executed only
% once)
index=1;
for j=1:length(Time_steady_Q)
    for k = 1:length(P_batt_Q)
        for l = 1:length(P_FC_Q)
            for m = 1:length(SOC_Q)
                Q_states(index,1)=Time_steady_Q(j);
                Q_states(index,2)=P_batt_Q(k);
                Q_states(index,3)=P_FC_Q(l);
                Q_states(index,4)=SOC_Q(m);
                index=index+1;
            end
        end
    end
end

% Assign the Q-state matrix in the base WS (for user analysis, not used for
% ML calculation)
assignin('base','Q_states',Q_states);



% #########################################################################
% ###############                ACTIONS             ######################
% #########################################################################

% The only action on the grid from the EMS is on the FC current.
dI_FC_Q=0.2; %p.u.
actions=[0 -dI_FC_Q dI_FC_Q];
% NB: Must be consistent with the number of columns in the Q-matrix


% #########################################################################
% ###############                AGENT               ######################
% #########################################################################

% Q matrix:
% Lines: states | columns: actions (same number than above)
Q = repmat(zeros(size(Q_states,1),1,'single'),[1,3]);

% The Q matrix can also be charged from previous simulations here with the
% load() function

% Matrix to keep track of the actions taken.
% Used for the adaptative learning rate calculation ("Average Q factor
% method")
Q_visited = zeros(size(Q));



% #########################################################################
% ###############          Q-learning SETTINGS         ####################
% #########################################################################

% How many episodes of testing ? (i.e. how many courses the system attend?)
maxEpi = simParam.maxEpi;

% Choose model
model = simParam.model;

% Set the (approximate) duration of one episode:
totalTime = simParam.totalTime;

% Set the length of one iteration in the simulink model
iterationTime = simParam.iterationTime;

% Confidence in new trials?
learnRate = simParam.learnRate;

% Exploration vs exploitation
epsilon = simParam.epsilon; % Initial value generaly equal to 0.5
epsilonDecay = simParam.epsilonDecay; % Decay factor per iteration

% Future vs present value
% Should be close to 1 (e.g. 0.999) for the maximum learning time horizon
discount = simParam.discount;

% Inject some noise?
successRate = simParam.successRate; % No noise : 1

% Where to store the results
resultPath = [simParam.parentFolder '\' simParam.subFolder '\'];
mkdir(resultPath);


% #########################################################################
% ################      INITIALIZE THE SIMULATION     #####################
% #########################################################################

% Calculates the number of iterations (must be integer)
maxit = floor(totalTime/iterationTime);

% Buffer load profile.
% When the system is off for longer than tStopLearning, the learning should
% stop to avoid modifying the Q-matrix during this period.
% This buffer contains the load value, and the system is considered to be
% off when the buffer is only filled with zeros (and the SOC not low).

tStopLearning = 6; % Stop the learning 6sec after the system turns off.
loadBufferLength = floor(tStopLearning/iterationTime);
loadBuffer = ones(loadBufferLength,1)'; % Initialized to 1 to learn at launching.
loadBufferIdle = zeros(loadBufferLength,1)'; % Buffer to test the equality with.


% Empty structure containing the discretized datas for one episode (filled
% with the end value of each iteration)
systemStatesTab = struct(...
    'time',transpose(0:iterationTime:maxit*iterationTime)...
    ,'P_FC',zeros(maxit+1,1)...
    ,'P_Batt',zeros(maxit+1,1)...
    ,'SOC_battery',zeros(maxit+1,1)...
    ,'Load_profile',zeros(maxit+1,1)...
    ,'Setpoint_I_FC',zeros(maxit+1,1)...
    ,'isExploitationAction',zeros(maxit+1,1)...
    ,'Stack_efficiency',zeros(maxit+1,1)...
    ,'reward_SOC',zeros(maxit+1,1)...
    ,'reward_P_FC',zeros(maxit+1,1)...
    ,'reward_P_batt',zeros(maxit+1,1)...
    ,'reward_Steady',zeros(maxit+1,1)...
    ,'reward',zeros(maxit+1,1));
% NOTE: This structure is overwritten each iteration.
% Has one more comumn than the number of iteration to include the initial
% state, and then generate rate of changes (feature used in previous
% versions).

% Empty structure containing continuous datas for one episode (filled with
% data collected all along the iteration)
continuousData = struct(...
    'time',[]...
    ,'P_FC',[]...
    ,'P_Batt',[]...
    ,'SOC_battery',[]...
    ,'Load_profile',timeseries()...
    ,'Stack_efficiency',[]);
% The size of this structure is unknown (depending on Simulink auto time
% step solver)

% Initialize a .txt file containing relevant datas
delete([resultPath 'results.txt']);
resultsReport = fopen([resultPath 'results.txt'],'w');
fprintf(resultsReport,[datestr(now) '\r\n']);
fprintf(resultsReport,['Model used: ' model '\r\n']);
fprintf(resultsReport,'Learning rate %2.2f \r\n', learnRate);
fprintf(resultsReport,'Epsilon start: %2.2f, epsilonDecay %2.7f\r\n',epsilon,epsilonDecay);
fprintf(resultsReport,'Discount: %3.3f\r\n', discount);
fprintf(resultsReport,'Number of episodes planned: %i\r\n', maxEpi);
fprintf(resultsReport,'Weight SOC: %3.3f\r\n',simParam.weightSOC);
fprintf(resultsReport,'Weight FC power: %3.3f\r\n',simParam.weightP_FC);
fprintf(resultsReport,'Weight Battery power: %3.3f\r\n',simParam.weightP_batt);
fprintf(resultsReport,'Weight Steady power: %3.3f\r\n',simParam.weightSteady);
fprintf(resultsReport,'Total time per episode: %5.1fs, Iteration time: %3.2fs\r\n',totalTime,iterationTime);
fprintf(resultsReport,'_______________\r\n\r\n');

% #########################################################################
% #############              START LEARNING              ##################
% #########################################################################

for episodes = 1:maxEpi
    
    % Reinitialize the time vector for continuous data at each episode:
    continuousData.time = [];
    continuousData.P_FC = [];
    continuousData.P_Batt = [];
    continuousData.SOC_battery = [];
    continuousData.Load_profile = timeseries();
    continuousData.Stack_efficiency = [];
    
    
    % Is the episode finished properly ?
    % Feature currently not useful, but might be necessary later
    completed = false; % Boolean checking the completion of the episode
    
    while ~completed
        % $$$$$$$$$$$$$$$     INITIALIZE THE EPISODE      $$$$$$$$$$$$$$$$$$$$$
        
        % Measure the simulation time
        t_SimulinkTotal = 0; % For the time running in Simulink
        t_LearningStart = cputime; % For the total time (Simulink + Learning)
        
        % Load the initial conditions and set the load profile
        % NB: At this level is decided the initial condition
        
        
        % % % %         load('initialState_30Ah.mat');
        m = mod(episodes,5);
        switch m
            case 0
                load('initialState_1_5Ah_70.mat');
            case 1
                load('initialState_1_5Ah_100.mat');
            case 2
                load('initialState_1_5Ah_30.mat');
            case 3
                load('initialState_1_5Ah_85.mat');
            case 4
                load('initialState_1_5Ah_50.mat');
        end
        
        inputArray(2) = 10; % Realistic load profile
        
        % Uncomment this to learn with other load profiles:
        %         n = mod(episodes,8);
        %         switch n
        %             case 0
        %                 inputArray(2) = 2; % Full load
        %             case 1
        %                 inputArray(2) = 8; % Sinus period 60sec
        %             case 2
        %                 inputArray(2) = 7; % Sinus period 5sec
        %             case 3
        %                 inputArray(2) = 1; % 50% constant load
        %             case 4
        %                 inputArray(2) = 4; % Pulse 5sec
        %             case 5
        %                 inputArray(2) = 5; % Pulse 60sec
        %             case 6
        %                 inputArray(2) = 10; % Realistic load
        %             case 7
        %                 inputArray(2) = 10; % Realistic load
        %         end
        
        % Loading the SimState
        currentSimState = initialSimState;
        
        % Initial time (time when the iterations start) (used for plotting)
        t_init = initialSimState.snapshotTime;
        
        % Charge the input for initial time: inputArray
        % (the input cannot ba calculated for initial time)
        % Column 1: Command for the FC current at the bus interface (i.e. between
        %        DC/DC conveter and bus. Unit is p.u. (base is the load).
        % Column 2: Load profile (code for each profile)
        inputsFromWS = Simulink.Parameter(inputArray);
        inputsFromWS.StorageClass='ExportedGlobal';
        %...should find how to avoid global...
        
        
        % Initialize the the model constants to ensure consistency with the
        % initialization phase
        % (model_constants loaded above)
        initialize_model_constants(model,model_constants);
        
        % Open the model and set the simulation modes
        % NB: At this point, the initial state must be known
        load_system(model);
        set_param(model,'SaveFinalState','on','FinalStateName','myOperPoint',...
            'SaveCompleteFinalSimState','on','LoadInitialState','on');
        set_param(model,'SimulationMode','accelerator');
        set_param(model,'FastRestart','on'); % No recompllling of the model between iterations
        
        % Initialize the value recording the number of constant actions
        % taken in a row (to fill the state):
        timeSteady = 0;
        
        % Starting point
        Q_state_struct = struct(...
            'Time_steady',timeSteady,...
            'P_batt',initial_outputsToWS.P_batt,...
            'P_FC',initial_outputsToWS.P_FC,...
            'SOC',initial_outputsToWS.SOC);
        
        % Convert the structure to array for use in the Q-learning calculation
        Q_state_array = transpose(cell2mat(struct2cell(Q_state_struct)));
        
        % Number of exploitation actions (non-random actions)
        % For result analysis (not for ML calculation)
        nExploitation = 0;
        
        % Initialize boolean for the case SOC < 10% (causing crash in simulink)
        lowSOC = 0;
        
        % Initialize the number of "forced" constant actions
        % Used during the decay phase, to teach the agent how to take
        % sequence of constant inputs
        steadyCounter = 0;
        
        
        try % Allow error during episode without compromising the next episodes
            
            % Go for one episode of maxit iterations
            for h = 1:maxit
                g = h + 1; % Do not write the first line (initial values)
                fprintf('Episode n.%i, iteration n.%i/%i\n',episodes,h,maxit);
                
                % $$$$$$$$$$$$$$$$$$     Pick an action     $$$$$$$$$$$$$$$$$$$$$$$
                % Interpolate the state within our discretization (ONLY for
                % choosing the action. We do not actually change the state by doing
                % this!)
                [~,sIdx] = min(sum((Q_states - repmat(Q_state_array,[size(Q_states,1),1])).^2,2));
                % sIdx is the line index of the state matrix corresponding the best to
                % the current_state.
                
                % $$$$$$$$$$$$$$$$$    Choose an action    $$$$$$$$$$$$$$$$$$$$$$$$
                
                
                rng('shuffle'); % Avoid repeated sequence of random mumbers
                
                if steadyCounter <= 0  % Are we in a sequence of forced constant actions ? Negative means no
                    
                    % EITHER 1) pick the best action according the Q matrix (EXPLOITATION).
                    if rand()>min(1,epsilon)... % Probability of aking an exploitation action according to the decay
                            && rand()<=successRate... % Fail the check if our action doesn't succeed (i.e. simulating noise)
                            && ((Q(sIdx,1)~=Q(sIdx,2)) && (Q(sIdx,1)~=Q(sIdx,3)))   % Take a random action when all the action coefficients are equals
                        
                        [~,aIdx_fc] = max(Q(sIdx,:)); % Pick the action (for the FC current) the Q matrix thinks is best
                        systemStatesTab.isExploitationAction(g) = 0.2; % For displaying only
                        nExploitation = nExploitation + 1;
                        
                        % OR 2) Pick a random action (EXPLORATION)
                    else
                        rng('shuffle'); % Avoid repeated sequence of random mumbers
                        if rand()<(1-probability_Forced_Constant_Sequence) % Take a random action following the normal process
                            rng('shuffle'); % Avoid repeated sequence of random mumbers
                            aIdx_fc = randi(size(actions,2),1); % Random action for FC!
                            systemStatesTab.isExploitationAction(g) = 0; % For displaying only
                        else % Trigger a sequence of n consecutive constant actions (i.e. help the system to learn how to keep constant input)
                            steadyCounter = 8; % The length of the sequence of constant actions we want to force
                            systemStatesTab.isExploitationAction(g) = -0.2; % For displaying only
                            steadyCounter = steadyCounter - 1;
                            aIdx_fc = 1;
                        end
                    end
                    
                else % Continue the sequence of consecutive constant actions
                    systemStatesTab.isExploitationAction(g) = -0.2; % For displaying only
                    steadyCounter = steadyCounter - 1;
                    aIdx_fc = 1;
                end
                
                % Count the number of times the input is constant for
                % rewarding (for both exploration and exploitation).
                if aIdx_fc == 1
                    timeSteady = timeSteady + 1; % Time means number of iterations
                else
                    timeSteady = 0;
                end
                
                
                % $$$$$$$$$$$$$$$$$    Run the model    $$$$$$$$$$$$$$$$$$$$$$$$$$$
                
                % New input for the model:
                dI_FC_Q = actions(1,aIdx_fc);
                inputArray(1) = inputArray(1) + dI_FC_Q;
                % Keep the I_FC_Q in bounds (redundant with limiters in the
                % simulink model, but accelerates convergence)
                if inputArray(1)<0
                    inputArray(1)=0;
                elseif inputArray(1)>1.8
                    inputArray(1)=1.8;
                end
                inputsFromWS.Value = inputArray;
                
                % Run ths Simulink model for iterationTime
                diary on
                t_SimulinkIterationStart = cputime;
                [currentSimState,simOut] = run_simulation(model,currentSimState,iterationTime);
                t_SimulinkTotal = t_SimulinkTotal + cputime - t_SimulinkIterationStart;
                diary off
                
                % Collect the results of the iteration (last value returned by the model):
                systemStatesTab.P_FC(g)  = simOut.outputsToWS.P_FC.Data(end);
                systemStatesTab.P_Batt(g) = simOut.outputsToWS.P_batt.Data(end);
                systemStatesTab.SOC_battery(g) = simOut.outputsToWS.SOC.Data(end);
                systemStatesTab.Stack_efficiency(g) = simOut.outputsToWS.Stack_efficiency.Data(end);
                systemStatesTab.Setpoint_I_FC(g) = inputArray(1);
                systemStatesTab.Load_profile(g) = simOut.outputsToWS.Load_profile.Data(end);
                systemOn = 1;
                loadBuffer(mod(g,loadBufferLength)+1) = systemStatesTab.Load_profile(g);
                if isequal(loadBuffer,loadBufferIdle) && simOut.outputsToWS.P_batt.Data(end) < 0.7 % Stop learning when no load and battery not under charged.
                    systemOn = 0;
                end
                
                continuousData.time = [continuousData.time simOut.tout'];
                continuousData.P_FC = [continuousData.P_FC simOut.outputsToWS.P_FC.Data'];
                continuousData.P_Batt = [continuousData.P_Batt simOut.outputsToWS.P_batt.Data'];
                continuousData.SOC_battery = [continuousData.SOC_battery simOut.outputsToWS.SOC.Data'];
                continuousData.Load_profile = append(continuousData.Load_profile,simOut.outputsToWS.Load_profile);
                continuousData.Stack_efficiency = [continuousData.Stack_efficiency simOut.outputsToWS.Stack_efficiency.Data'];
                
                
                
                % Fill the Q-learning state
                Q_state_struct.Time_steady = timeSteady;
                Q_state_struct.P_batt = mean(simOut.outputsToWS.P_batt.Data); % Take the average value on the last iteration (kind of LPF for freq. greater than f_learning)
                Q_state_struct.P_FC = simOut.outputsToWS.P_FC.Data(end);
                Q_state_struct.SOC = simOut.outputsToWS.SOC.Data(end);
                
                
                % Convert the structure to array for use in the Q-learning calculation
                Q_state_array = transpose(cell2mat(struct2cell(Q_state_struct)));
                
                % $$$$$$$$$$$$$$$$    Calculate the reward     $$$$$$$$$$$$$$$$$$$$
                [rSOC,rP_FC,rP_batt,rSteady] = getReward(Q_state_struct,aIdx_fc);
                reward = ...
                    simParam.weightSOC*rSOC +...
                    simParam.weightP_FC*isP_FCConsidered*rP_FC +...
                    simParam.weightP_batt*isP_battConsidered*rP_batt +...
                    simParam.weightSteady*isTimeSteadyConsidered*rSteady;
                fprintf('SOC %3.3f\n',Q_state_struct.SOC);
                systemStatesTab.reward(g) = reward;
                % Save rewards individualy to evaluate the quality of the
                % policy regarding a single criterion:
                systemStatesTab.reward_SOC(g) = rSOC;
                systemStatesTab.reward_P_FC(g) = rP_FC;
                systemStatesTab.reward_P_batt(g) = rP_batt;
                systemStatesTab.reward_Steady(g) = rSteady;
                
                
                % $$$$$$$$$$$$$$$$   Update the Q-matrix    $$$$$$$$$$$$$$$$$$$$$$$
                % Interpolate again to find the new state the system is closest to.
                [~,snewIdx] = min(sum((Q_states - repmat(Q_state_array,[size(Q_states,1),1])).^2,2)); % Interpolate again to find the new state the system is closest to.
                
                % Update Q
                Q(sIdx,aIdx_fc) = Q(sIdx,aIdx_fc) + (1/(Q_visited(sIdx,aIdx_fc)+1)) * systemOn * ( reward + discount*max(Q(snewIdx,:)) - Q(sIdx,aIdx_fc) ); % The line that makes everything !!!
                fprintf('State index %i\n',sIdx);
                fprintf('Reward %2.2f\n',reward);
                fprintf('Q(sIdx,aIdx_fc) %3.2f\n',Q(sIdx,aIdx_fc));
                
                % Make the action visited one more time
                Q_visited(sIdx,aIdx_fc) = Q_visited(sIdx,aIdx_fc) + 1;
                
                % Decay the odds of picking a random action vs picking the
                % estimated "best" action. I.e. we're becoming more confident in
                % our learned Q.
                epsilon = epsilon*epsilonDecay;
                
                % Break the iteration if SOC < 10%
                if simOut.outputsToWS.SOC.Data(end) < 0.1
                    lowSOC = 1;
                    break
                end
            end % end iterations counting for single episode
            
            
            % The episode finished properly if this point is reached
            completed = 1;
            
            
            % $$$$$$$$$$$$$$$$       PLOTTING       $$$$$$$$$$$$$$$$$$$$$$$
            % Analysis of the episode performance
            if ~lowSOC
                t_LearningTotal = cputime - t_LearningStart;
                fprintf(resultsReport,'Episode %i: \r\n',episodes);
                ratioExploitation = (nExploitation/maxit)*100;
                fprintf(resultsReport,'Exploitation actions: %3.2f%% \r\n',ratioExploitation);
                fprintf(resultsReport,'Epsilon (end of iteration): %2.3f \r\n',epsilon);
                fprintf(resultsReport,'Simulink time: %5.1fs \r\n',t_SimulinkTotal);
                fprintf(resultsReport,'Episode duration (Simulink + Q-process): %5.1fs \r\n',t_LearningTotal);
                ratioTime = (t_SimulinkTotal/t_LearningTotal)*100;
                fprintf(resultsReport,'Ratio Simulink/Total time for episode: %3.2f%% \r\n',ratioTime);
                fprintf(resultsReport,'_______________\r\n\r\n');
                
                % Resample the continuous data at f=1Hz
                continuousData.time = continuousData.time - t_init; % Remove the initialization time in the continuous data
                resampledData = struct(...
                    'time',[]...
                    ,'P_FC',[]...
                    ,'P_Batt',[]...
                    ,'SOC_battery',[]...
                    ,'Load_profile',timeseries()...
                    ,'Stack_efficiency',[]);
                
                
                tEnd = floor(continuousData.time(end));
                resampledData.time = zeros(tEnd+1,1);
                for i = 0:tEnd
                    resampledData.time(i+1) = i; % Resample at a rate of 1Hz (one value each sec)
                end
                [x, index] = unique(continuousData.time);
                resampledData.P_FC = interp1(x,continuousData.P_FC(index),resampledData.time);
                resampledData.P_Batt = interp1(x,continuousData.P_Batt(index),resampledData.time);
                resampledData.SOC_battery = interp1(x,continuousData.SOC_battery(index),resampledData.time);
                resampledData.Load_profile = resample(continuousData.Load_profile,resampledData.time);
                resampledData.Stack_efficiency = interp1(x,continuousData.Stack_efficiency(index),resampledData.time);
                
                % Plotting the result of the episode
                fig = figure(episodes);
                
                subplot(411);
                h(1) = plot(systemStatesTab.time(2:end),systemStatesTab.SOC_battery(2:end),'.');
                hold on
                h(2) = bar(systemStatesTab.time(2:end),systemStatesTab.isExploitationAction(2:end));
                h(3) = line([systemStatesTab.time(1),systemStatesTab.time(end)],[0.6,0.6],'Color','k','LineStyle',':');
                h(4) = line([systemStatesTab.time(1),systemStatesTab.time(end)],[0.8,0.8],'Color','k','LineStyle',':');
                h(5) = plot(resampledData.time,resampledData.SOC_battery,'-');
                legend(h([1 2 5]),'Processing point','Exploitation','SOC','Location','southwest');
                
                subplot(412)
                plot(systemStatesTab.time(2:end),systemStatesTab.reward(2:end),'*-');
                hold on
                plot(resampledData.time,resampledData.P_Batt,'-');
                plot(systemStatesTab.time(2:end),systemStatesTab.P_Batt(2:end),'.');
                legend('Reward','P Batt','Location','southwest');
                
                subplot(413);
                plot(systemStatesTab.time(2:end),systemStatesTab.Setpoint_I_FC(2:end),'.-');
                hold on
                plot(resampledData.time,resampledData.P_FC,'-');
                plot(resampledData.Load_profile,'-');
                legend('I FC (p.u.)','P FC (p.u.)','Load profile (p.u.)','Location','southwest');
                
                subplot(414)
                plot(systemStatesTab.time(2:end),systemStatesTab.reward_SOC(2:end),'.-');
                hold on
                plot(systemStatesTab.time(2:end),systemStatesTab.reward_P_FC(2:end),'.-');
                plot(systemStatesTab.time(2:end),systemStatesTab.reward_P_batt(2:end),'.-');
                plot(systemStatesTab.time(2:end),systemStatesTab.reward_Steady(2:end),'.-');
                legend('rSOC','rP FC','rP batt','rSteady','Location','southwest');
                
                drawnow
                saveas(fig,[resultPath 'episode' num2str(episodes) '.fig']);
                saveas(fig,[resultPath 'episode' num2str(episodes) '.jpg']);
                close(fig);
                
                % Save the Q-matrix
                save([resultPath 'Q_episode' num2str(episodes) '.mat'],'Q');
                save([resultPath 'Q_visited_episode' num2str(episodes) '.mat'],'Q_visited');
                
                % Save the data collected
                save([resultPath 'Data_episode' num2str(episodes) '.mat'],'systemStatesTab','resampledData');
            else
                fprintf(resultsReport,'Episode %i: \r\n',episodes);
                fprintf(resultsReport,'Failure, SOC too close to 0\r\n');
                fprintf(resultsReport,'_______________\r\n\r\n');
            end
            
        catch
            fprintf(resultsReport,'Episode %i: \r\n',episodes);
            fprintf(resultsReport,'Error occured, go to next episode\r\n');
            fprintf(resultsReport,'_______________\r\n\r\n');
            set_param(model,'FastRestart','off');
            close_system(model,0);
            load_system(model);
            set_param(model,'SimulationCommand','update')
            completed = 1;
        end % end try catch
        
        % Close the model without saving it
        set_param(model,'FastRestart','off');
        close_system(model,0); % Seem that the simulations are longer when restarting from an already opened model
        
    end % end while episode not completed
end % end episodes counting

% Close the text file
fclose(resultsReport);