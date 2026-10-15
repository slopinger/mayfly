-module(boymoder_slop_box_clock).
-export([now/0]).
now() -> erlang:system_time(second).
