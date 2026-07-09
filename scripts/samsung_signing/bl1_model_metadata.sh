#!/usr/bin/env bash

PRINT_SAMSUNG_BL1_SUPPORTED_MODELS()
{
    echo "G780F G980F G981B G985F G986B G988B N980F N981B N985F N986B"
}

GET_SAMSUNG_BL1_MODEL_METADATA()
{
    case "${1^^}" in
        "G780F")
            echo "0x154 11"
            ;;
        "G980F")
            echo "0x143 11"
            ;;
        "G981B")
            echo "0x13D 11"
            ;;
        "G985F")
            echo "0x142 11"
            ;;
        "G986B")
            echo "0x13C 11"
            ;;
        "G988B")
            echo "0x13E 11"
            ;;
        "N980F")
            echo "0x153 11"
            ;;
        "N981B")
            echo "0x14E 11"
            ;;
        "N985F")
            echo "0x152 11"
            ;;
        "N986B")
            echo "0x14D 11"
            ;;
        *)
            return 1
            ;;
    esac
}
