-module(slopbox_clock).
-export([now/0]).
now() -> erlang:system_time(second).
