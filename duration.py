import warnings
warnings.filterwarnings('ignore')
import sys
import os
import re
import numpy as np

regexPHP = re.compile('200\s(\d+(\.\d*)?|\.\d+)ms')
regexNGNX = re.compile('\"rt=(\d+(\.\d*)?|\.\d+)')
regexDB = re.compile('#\sQuery_time\:\s(\d+(\.\d+)?)')

ARR_SWAP_TYPE = ["private"]
ARR_SCALE = [4]

def get_val(LOG_PATH):
    
    arr_val = []
    if os.path.isfile(LOG_PATH):
        with open(LOG_PATH) as f:
            f.seek(0)
            for line in f:
                if "php" in LOG_PATH:
                    match = regexPHP.search(line)
                elif "nginx" in LOG_PATH:
                    match = regexNGNX.search(line)
                else:
                    match = regexDB.search(line)

                if match:
                    arr_val.append(float(match.group(1)))

    return arr_val

def main():
    print("total-duration nginx php mysql")
    for SWAP_TYPE in ARR_SWAP_TYPE:
        for NUM_SCALE in ARR_SCALE:
            arr_php, arr_nginx, arr_mysql = [], [], []
            for SCALE_ID in range(1, NUM_SCALE + 1):
                PHP_PATH = "/mnt/data/cont-web/swap-" + SWAP_TYPE + "/SCALE" + str(NUM_SCALE) + "/php" + str(SCALE_ID) + ".log"
                NGNX_PATH = "/mnt/data/cont-web/swap-" + SWAP_TYPE + "/SCALE" + str(NUM_SCALE) + "/nginx" + str(SCALE_ID) + ".log"
                MYSQL_PATH = "/mnt/data/cont-web/swap-" + SWAP_TYPE + "/SCALE" + str(NUM_SCALE) + "/mysql" + str(SCALE_ID) + ".log"

                arr_php = get_val(PHP_PATH)
                arr_nginx = get_val(NGNX_PATH)
                arr_mysql = get_val(MYSQL_PATH)

                sum_php = np.sum(arr_php)
                sum_nginx = np.sum(arr_nginx) * 1000
                sum_mysql = np.sum(arr_mysql) * 1000

                # perc95_php = np.percentile(arr_php, 95)
                # perc95_nginx = np.percentile(arr_nginx, 95)
                # perc95_mysql = np.percentile(arr_mysql, 95)
        
                if SWAP_TYPE == "private":
                    # print("indep-ID" + str(SCALE_ID) + " " + str(sum_nginx))
                    print("indep-ID" + str(SCALE_ID) + " " + str(sum_nginx - sum_php) + " " + str(sum_php - sum_mysql) + " " + str(sum_mysql))
                    #print("indep-ID" + str(SCALE_ID) + " " + str(perc95_php) + " " + str(perc95_nginx)+ " " + str(perc95_mysql))
                else:
                    # print("shared-ID" + str(SCALE_ID) + " " + str(sum_nginx))
                    print("shared-ID" + str(SCALE_ID) + " " + str(sum_nginx - sum_php) + " " + str(sum_php - sum_mysql) + " " + str(sum_mysql))
                    #print("shared-ID" + str(SCALE_ID) + " " + str(perc95_php) + " " + str(perc95_nginx)+ " " + str(perc95_mysql))


if __name__ == "__main__":
    main()
