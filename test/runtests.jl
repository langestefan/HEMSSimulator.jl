using BatteryBusinessCase
using TestItemRunner

# `:network` test items hit Open-Meteo and ENTSO-E for real. They are excluded here so the suite
# stays runnable offline and in CI; run them deliberately with
#
#     julia --project=test -e 'using TestItemRunner; \
#         TestItemRunner.run_tests("."; filter = ti -> :network in ti.tags)'
#
# The ENTSO-E ones additionally need ENV["ENTSOE_API_TOKEN"].
@run_package_tests verbose = true filter = ti -> !(:network in ti.tags)
