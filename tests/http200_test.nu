const suite = (path self | path dirname | path join http200_test.py)
def main [] { ^python3 $suite; if $env.LAST_EXIT_CODE != 0 { exit $env.LAST_EXIT_CODE } }
