% DESCRIPTION:
% Script executing everything in the right order.

%% Initialization (generate various initial states)
init_for_DC_grid

%%
clear all
close all
clc

%% Initialize the parameters for learning session:
simulation_parameters_1 = struct(...
    'model','DC_grid_V2',...
    'maxEpi',1000,...
    'totalTime',2000,...
    'iterationTime',2.6,...
    'learnRate',0.1,...
    'epsilon',2,...
    'epsilonDecay',0.99994,...
    'discount',0.999,...
    'successRate',1,...
    'weightSOC',1,...
    'weightP_FC',1,...
    'weightP_batt',1,...
    'weightSteady',1,...
    'subFolder','Constant_command_forced'...
    );



%% Run Machine Learning
global inputsFromWS
directory = '30_july_day';
QlearningEMS(simulation_parameters_1,directory);

