#!/bin/bash -xeE
export PATH=/hpc/local/bin::/usr/local/bin:/bin:/usr/bin:/usr/sbin:${PATH}

help_txt_list=${help_txt_list:="oshmem ompi/mca/mtl/mxm ompi/mca/coll/fca ompi/mca/coll/hcoll"}
hca_port=${hca_port:=1}
jenkins_test_build=${jenkins_test_build:="yes"}
jenkins_test_examples=${jenkins_test_examples:="yes"}
jenkins_test_oshmem=${jenkins_test_oshmem:="yes"}
jenkins_test_vader=${jenkins_test_vader:="yes"}
jenkins_test_check=${jenkins_test_check:="yes"}
jenkins_test_src_rpm=${jenkins_test_src_rpm:="no"}
jenkins_test_help_txt=${jenkins_test_help_txt:="no"}
jenkins_test_threads=${jenkins_test_threads:="yes"}
jenkins_test_cov=${jenkins_test_cov:="yes"}
jenkins_test_known_issues=${jenkins_test_known_issues:="no"}
jenkins_test_all=${jenkins_test_all:="no"}
jenkins_test_debug=${jenkins_test_debug:="no"}
timeout_exe=${timout_exe:="timeout -s SIGKILL 10m"}

# internal flags to select/unselect OMPI transports used in test
btl_tcp=${btl_tcp:="yes"}
btl_sm=${btl_sm:="yes"}
btl_openib=${btl_openib:="yes"}
btl_vader=${btl_vader:="yes"}

# TAP directive for MLNX modules in coverity
# empty - treat errors as failures
# can be TODO, SKIP
mlnx_cov="TODO"

# prepare to run from command line w/o jenkins
if [ -z "$WORKSPACE" ]; then
    WORKSPACE=$PWD
    JOB_URL=$WORKSPACE
    BUILD_NUMBER=1
    JENKINS_RUN_TESTS=yes
    NOJENKINS=${NOJENKINS:="yes"}
    ghprbTargetBranch=${ghprbTargetBranch:="mellanox-v1.8"}
fi

gh_cov_msg="$WORKSPACE/cov_file_${BUILD_NUMBER}.txt"
OMPI_HOME1=$WORKSPACE/ompi_install1
ompi_home_list="$OMPI_HOME1"
topdir=$WORKSPACE/rpms
tarball_dir=${WORKSPACE}/tarball
check_help_exe="$WORKSPACE/contrib/check-help-strings.pl"

make_opt="-j$(nproc)"

# extract jenkins commands from function args
function check_commands
{
    local cmd=$1
    local pat=""
    local test_list="threads src_rpm oshmem check help_txt known_issues cov all"
    for pat in $(echo $test_list); do
        echo -n "checking $pat "
        if [[ $cmd =~ jenkins\:.*no${pat}.* ]]; then
            echo disabling 
            eval "jenkins_test_${pat}=no"
        elif [[ $cmd =~ jenkins\:.*${pat}.* ]]; then
            echo enabling
            eval "jenkins_test_${pat}=yes"
        else
            echo no directive for ${pat}
        fi
    done

    if [ "$jenkins_test_all" = "yes" ]; then
        echo Enabling all tests
        for pat in $(echo $test_list); do
            eval "jenkins_test_${pat}=yes"
        done
    fi
}

# check for jenkins commands in PR title
if [ -n "$ghprbPullTitle" ]; then
    check_commands "$ghprbPullTitle"
fi

# check for jenkins command in PR last comment
if [ -n "$ghprbPullLink" ]; then
    set +xeE
    pr_url=$(echo $ghprbPullLink | sed -e s,github.com,api.github.com/repos,g -e s,pull,issues,g)
    pr_url="${pr_url}/comments"
    pr_file="$WORKSPACE/github_pr_${ghprbPullId}.json"
    curl -s $pr_url > $pr_file
    echo Fetching PR comments from URL: $pr_url

    # extracting last comment
    pr_comments="$(cat $pr_file | jq -M -a '.[length-1] | .body')"

    echo Last comment: $pr_comments
    if [ -n "$pr_comments" ]; then
        check_commands "$pr_comments"
    fi
    set -xeE
fi


if [ "$jenkins_test_debug" = "no" ]; then
    if [ $ghprbTargetBranch == "mellanox-v1.8" ]; then
        jenkins_test_threads=yes
        jenkins_test_oshmem=yes
        jenkins_test_help_txt=yes
        jenkins_test_src_rpm=yes
        jenkins_test_cov=yes
    fi

    if [ $ghprbTargetBranch == "v1.8" ]; then
        jenkins_test_threads=yes
        jenkins_test_oshmem=yes
        jenkins_test_src_rpm=yes
        mlnx_cov="SKIP"
    fi
fi

if [ -n "$NOJENKINS" -a -d $OMPI_HOME1 ]; then
    jenkins_test_build=no
    jenkins_test_src_rpm=no
    jenkins_build_passed=1
fi

echo Running following tests:
set|grep jenkins_test_

if [ "$jenkins_test_threads" = "yes" ]; then
    extra_conf="--enable-mpi-thread-multiple --enable-opal-multi-threads"
fi


function mpi_runner()
{
    local np=$1
    local exe_path=$2
    local exe_args=${3}
    local common_mca="-bind-to core"
    local mca="$common_mca"

    if [ "$btl_tcp" == "yes" ]; then
        $timeout_exe mpirun -np $np $mca -mca pml ob1 -mca btl self,tcp   ${exe_path} ${exe_args}
    fi

    if [ "$btl_sm" == "yes" ]; then
        $timeout_exe mpirun -np $np $mca -mca pml ob1 -mca btl self,sm    ${exe_path} ${exe_args}
    fi

    if [ "$btl_vader" == "yes" ]; then
        $timeout_exe mpirun -np $np $mca -mca pml ob1 -mca btl self,vader ${exe_path} ${exe_args}
    fi


    local val=$(ompi_info --param pml all --level 9 | grep yalla | wc -l)
    for hca_dev in $(ibstat -l); do

        if [ -f "$exe_path" ]; then
            local hca="${hca_dev}:${hca_port}"
            mca="$common_mca -mca btl_openib_if_include $hca -x MXM_RDMA_PORTS=$hca"

            echo "Running $exe_path ${exe_args}"

            if [ "$btl_openib" == "yes" ]; then
                $timeout_exe mpirun -np $np $mca -mca pml ob1 -mca btl self,openib      ${exe_path} ${exe_args}
            fi
            $timeout_exe mpirun -np $np $mca -mca pml cm  -mca mtl mxm                  ${exe_path} ${exe_args}
            if [ $val -gt 0 ]; then
                $timeout_exe mpirun -np $np $mca -mca pml yalla ${exe_path} ${exe_args}
            fi
        fi
    done
}

function oshmem_runner()
{
    local np=$1
    local exe_path=$2
    local exe_args=${3}
    local spml_yoda="--mca spml yoda"
    local spml_ikrit="--mca spml ikrit"

    oshmem_info -a -l 9
    local common_mca="--bind-to core -x SHMEM_SYMMETRIC_HEAP_SIZE=1024M"
    local mca="$common_mca"

    $timeout_exe oshrun -np $np $mca $spml_yoda  -mca pml ob1 -mca btl self,tcp   ${exe_path} ${exe_args}
    $timeout_exe oshrun -np $np $mca $spml_yoda  -mca pml ob1 -mca btl self,sm    ${exe_path} ${exe_args}

    if [ "$jenkins_test_vader" == "yes" ]; then
        $timeout_exe oshrun -np $np $mca $spml_yoda  -mca pml ob1 -mca btl self,vader ${exe_path} ${exe_args}
    fi


    for hca_dev in $(ibstat -l); do
        if [ -f "$exe_path" ]; then
            local hca="${hca_dev}:${hca_port}"
            mca="$common_mca"
            mca="$mca --mca btl_openib_if_include $hca -x MXM_RDMA_PORTS=$hca"
            mca="$mca --mca rmaps_base_dist_hca $hca --mca sshmem_verbs_hca_name $hca"
            echo "Running $exe_path ${exe_args}"
            $timeout_exe oshrun -np $np $mca $spml_yoda  -mca pml ob1 -mca btl self,openib    ${exe_path} ${exe_args}
            $timeout_exe oshrun -np $np $mca $spml_yoda  -mca pml ob1 -mca btl self,sm,openib ${exe_path} ${exe_args}
            $timeout_exe oshrun -np $np $mca $spml_ikrit -mca pml cm  -mca mtl mxm            ${exe_path} ${exe_args}
        fi
    done
}

function on_start()
{
    echo Starting on host: $(hostname)

    export distro_name=$(python -c 'import platform ; print platform.dist()[0]' | tr '[:upper:]' '[:lower:]')
    export distro_ver=$(python  -c 'import platform ; print platform.dist()[1]' | tr '[:upper:]' '[:lower:]')
    if [ "$distro_name" == "suse" ]; then
        patch_level=$(egrep PATCHLEVEL /etc/SuSE-release|cut -f2 -d=|sed -e "s/ //g")
        if [ -n "$patch_level" ]; then
            export distro_ver="${distro_ver}.${patch_level}"
        fi
    fi
    echo $distro_name -- $distro_ver

    # save current environment to support debugging
    set +x
    env| sed -ne "s/\(\w*\)=\(.*\)\$/export \1='\2'/p" > $WORKSPACE/test_env.sh
    chmod 755 $WORKSPACE/test_env.sh
    set -x
}

function on_exit
{
    set +x
    rc=$((rc + $?))
    echo exit code=$rc
    if [ $rc -ne 0 ]; then
        # FIX: when rpmbuild fails, it leaves folders w/o any permissions even for owner
        # jenkins fails to remove such and fails
        find $topdir -type d -exec chmod +x {} \;
    fi
}

function test_cov
{
    local cov_build_dir=$1
    local cov_proj=$2
    local cov_url_webroot=$3
    local cov_make_cmd=$4
    local cov_directive=$5

    local nerrors=0;

    module load tools/cov
    rm -rf $cov_build_dir
    cov-build   --dir $cov_build_dir $cov_make_cmd
    cov-analyze --dir $cov_build_dir
    nerrors=$(cov-format-errors --dir $cov_build_dir | awk '/Processing [0-9]+ errors?/ { print $2 }')

    index_html=$(cd $cov_build_dir && find . -name index.html | cut -c 3-)
    local cov_url="$cov_url_webroot/${index_html}"

    if [ -n "$nerrors" ]; then
        if [ "$nerrors" = "0" ]; then
            echo ok - coverity found no issues for $cov_proj >> $cov_stat_tap
        else
            echo "not ok - coverity detected $nerrors failures in $cov_proj # $cov_directive $cov_url" >> $cov_stat_tap
            local cov_proj_disp="$(echo $cov_proj|cut -f1 -d_)"
            printf "%s\t%s\n" "coverity_for_${cov_proj_disp}" "$cov_url" >> $WORKSPACE/jenkins_sidelinks.txt
            echo Coverity report: $cov_url
            echo "" >> $gh_cov_msg
            echo "* Coverity found $nerrors errors for ${cov_proj_disp}: $cov_url" >> $gh_cov_msg
        fi
    else
        echo "not ok - coverity failed to run for $cov_proj # SKIP failed to init coverity" >> $cov_stat_tap
    fi

    module unload tools/cov

    return $nerrors
}


trap "on_exit" INT TERM ILL KILL FPE SEGV ALRM

on_start

if [ -x "autogen.sh" ]; then
    autogen_script=./autogen.sh
else
    autogen_script=./autogen.pl
fi


if [ "$jenkins_test_build" = "yes" ]; then
    echo "Building OMPI"

    # control mellanox platform file, select various configure flags
    export mellanox_autodetect=yes
    export mellanox_debug=yes

    configure_args="--with-platform=contrib/platform/mellanox/optimized --with-ompi-param-check --enable-picky $extra_conf"

    rm -rf $ompi_home_list 

    # build ompi
    $autogen_script && echo ./configure $configure_args --prefix=$OMPI_HOME1 | bash -xeE && make $make_opt install || exit 10

    jenkins_build_passed=1
fi

if [ -n "$jenkins_build_passed" ]; then
    # check coverity
    if [ "$jenkins_test_cov" = "yes" ]; then
        vpath_dir=$WORKSPACE
        cov_proj="all oshmem ompi/mca/pml/yalla ompi/mca/mtl/mxm ompi/mca/coll/fca ompi/mca/coll/hcoll"
        cov_stat=$vpath_dir/cov_stat.txt
        cov_stat_tap=$vpath_dir/cov_stat.tap
        cov_build_dir=$vpath_dir/cov_build
        cov_url_webroot=${JOB_URL}/ws/cov_build

        rm -f $cov_stat $cov_stat_tap

        if [ -d "$vpath_dir" ]; then
            mkdir -p $cov_build_dir
            pushd $vpath_dir
            for dir in $cov_proj; do
                if [ "$dir" = "all" ]; then
                    make_cov_opt=""
                    cov_directive="SKIP"
                else
                    if [ ! -d "$dir" ]; then
                        continue
                    fi
                    cov_directive=$mlnx_cov
                    make_cov_opt="-C $dir"
                fi
                echo Working on $dir

                cov_proj="$(basename $dir)_${BUILD_NUMBER}"
                cov_dir="$cov_build_dir/$cov_proj"
                set +eE
                make $make_cov_opt $make_opt clean 2>&1 > /dev/null
                test_cov $cov_dir $cov_proj "${cov_url_webroot}/${cov_proj}" "make $make_cov_opt $make_opt all" $cov_directive
                set -eE
            done
            if [ -n "$ghprbPullId" -a -f "$gh_cov_msg" ]; then
                gh pr $ghprbPullId --comment "$(cat $gh_cov_msg)"
            fi
            popd
        fi
    fi

    if [ "$jenkins_test_check" = "yes" ]; then
        make $make_opt check || exit 12
    fi
fi

if [ "$jenkins_test_src_rpm" = "yes" ]; then

    # check distclean
    make $make_opt distclean && $autogen_script && echo ./configure $configure_args --prefix=$OMPI_HOME1 | bash -xeE || exit 11

    if [ -x /usr/bin/dpkg-buildpackage ]; then
        echo "Building OMPI on debian"
        # debian is here - run and hide
        build_debian="contrib/dist/mofed/compile_debian_mlnx_example"
        if [ -x $build_debian ]; then
            $build_debian
        fi
    else
        echo "Building OMPI src.rpm"
        rm -rf $tarball_dir
        mkdir -p $tarball_dir

        make_dist_args="--highok --distdir $tarball_dir"

        for arg in no-git-update dirtyok verok; do
            if grep $arg contrib/dist/make_tarball 2>&1 > /dev/null; then 
                make_dist_args="$make_dist_args --${arg}"
            fi
        done

        chmod +x ./contrib/dist/make* ./contrib/dist/linux/buildrpm.sh
        echo contrib/dist/make_dist_tarball $make_dist_args | bash -xeE || exit 11

        # build src.rpm
        # svn_r=$(git rev-parse --short=7 HEAD| tr -d '\n') ./contrib/dist/make_tarball --distdir $tarball_dir
        tarball_src=$(ls -1 $tarball_dir/openmpi-*.tar.bz2|sort -h -r|head -1)

        echo "Building OMPI bin.rpm"
        rpm_flags="--define 'mflags $make_opt' --define '_source_filedigest_algorithm md5' --define '_binary_filedigest_algorithm md5'"
        (cd ./contrib/dist/linux && env rpmbuild_options="$rpm_flags" rpmtopdir=$topdir ./buildrpm.sh $tarball_src)
    fi
fi

#
# JENKINS_RUN_TESTS should be set in jenkins slave node to indicate that node can run tests
#
if [ -n "$JENKINS_RUN_TESTS" ]; then

    if [ "$jenkins_test_help_txt" = "yes" ]; then
        if [ -f $check_help_exe ]; then
            echo "Checking help strings"
            for dir in $(echo $help_txt_list); do
                if [ -d "$dir" ]; then
                    (cd $dir && $check_help_exe .)
                fi
            done
        fi
    fi


    for OMPI_HOME in $(echo $ompi_home_list); do

        if [ "$jenkins_test_examples" = "yes" ]; then 
            exe_dir=$OMPI_HOME/examples
            if [ ! -d "$exe_dir" ]; then 
                echo "Running examples for $OMPI_HOME"
                cp -prf ${WORKSPACE}/examples $OMPI_HOME
                (PATH=$OMPI_HOME/bin:$PATH LD_LIBRARY_PATH=$OMPI_HOME/lib:$LD_LIBRARY_PATH make -C $exe_dir all)
            fi
            for exe in hello_c ring_c; do 
                exe_path=${exe_dir}/$exe
                (PATH=$OMPI_HOME/bin:$PATH LD_LIBRARY_PATH=$OMPI_HOME/lib:$LD_LIBRARY_PATH mpi_runner 8 $exe_path)
            done

            if [ "$jenkins_test_oshmem" = "yes" ]; then 
                for exe in hello_oshmem oshmem_circular_shift oshmem_shmalloc oshmem_strided_puts oshmem_symmetric_data; do 
                    exe_path=${exe_dir}/$exe
                    (PATH=$OMPI_HOME/bin:$PATH LD_LIBRARY_PATH=$OMPI_HOME/lib:$LD_LIBRARY_PATH oshmem_runner 8 $exe_path)
                done
            fi
        fi

        if [ "$jenkins_test_threads" = "yes" ]; then 
            exe_dir=$OMPI_HOME/thread_tests
            if [ ! -d "$exe_dir" ]; then 
                pushd .
                mkdir -p $exe_dir
                cd $exe_dir
                wget --no-check-certificate http://www.mcs.anl.gov/~thakur/thread-tests/thread-tests-1.1.tar.gz
                tar zxf thread-tests-1.1.tar.gz
                cd thread-tests-1.1
                make CC=$OMPI_HOME/bin/mpicc
                popd
            fi

            # disabling btls which known to fail with threads
            if [ "$jenkins_test_known_issues" == "no" ]; then 
                btl_tcp=no
                btl_vader=no
                #btl_sm=no
            fi
            btl_openib=no
            for exe in overlap latency; do 
                exe_path=${exe_dir}/thread-tests-1.1/$exe
                (PATH=$OMPI_HOME/bin:$PATH LD_LIBRARY_PATH=$OMPI_HOME/lib:$LD_LIBRARY_PATH mpi_runner 4 $exe_path 8)
            done
            for exe in latency_th bw_th message_rate_th; do 
                exe_path=${exe_dir}/thread-tests-1.1/$exe
                (PATH=$OMPI_HOME/bin:$PATH LD_LIBRARY_PATH=$OMPI_HOME/lib:$LD_LIBRARY_PATH mpi_runner 2 $exe_path 8)
            done
            btl_openib=yes
            btl_tcp=yes
            btl_sm=yes
            btl_vader=yes
        fi
    done

    # todo: make dir structure with shell scripts to run as jenkins tests at the end
    for OMPI_HOME in $(echo $ompi_home_list); do
        echo "check if mca_base_env_list parameter is supported in $OMPI_HOME"
        val=$($OMPI_HOME/bin/ompi_info --param mca base --level 9 | grep mca_base_env_list | wc -l)
        if [ $val -gt 0 ]; then
            echo "test mca_base_env_list option in $OMPI_HOME"
            export XXX_C=3 XXX_D=4 XXX_E=5
            val=$($OMPI_HOME/bin/mpirun -np 2 -mca mca_base_env_list 'XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E' env|grep ^XXX_|wc -l)
            if [ $val -ne 10 ]; then
                exit 1
            fi

            # check amca param
cat>$WORKSPACE/env_mpi.c<<EOF
#include <stdio.h>
#include <stdlib.h>
#include <mpi.h>
int main(int argc, char **argv, char **env)
{
    int i=0;
    char *astr;
    MPI_Init(&argc,&argv);
    astr=env[i];
    while(astr) {
        printf("%s\n",astr);
        astr=env[++i];
    }
   MPI_Finalize();
}
EOF
            $OMPI_HOME/bin/mpicc -o $WORKSPACE/env_mpi $WORKSPACE/env_mpi.c
            echo "mca_base_env_list=XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E" > $WORKSPACE/test_amca.conf
            val=$($OMPI_HOME/bin/mpirun -np 2 -am $WORKSPACE/test_amca.conf $WORKSPACE/env_mpi |grep ^XXX_|wc -l)
            if [ $val -ne 10 ]; then
                if [ $ghprbTargetBranch == "mellanox-v1.8" ]; then
                    exit 1
                fi
            fi

            # testing -tune option (mca_base_envar_file_prefix mca parameter) which supports setting both mca and env vars
            echo "-x XXX_A=1   --x   XXX_B = 2 -x XXX_C -x XXX_D --x XXX_E" > $WORKSPACE/test_tune.conf
            val=$($OMPI_HOME/bin/mpirun -np 2 -tune $WORKSPACE/test_tune.conf -x XXX_A=6 $WORKSPACE/env_mpi | sed -n -e 's/^XXX_.*=//p' | sed -e ':a;N;$!ba;s/\n/+/g' | bc)
            # return (6+2+3+4+5)*2=40
            if [ $val -ne 40 ]; then
                if [ $ghprbTargetBranch == "mellanox-v1.8" ]; then
                    exit 1
                fi
            fi

            echo "-mca mca_base_env_list \"XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E\"" > $WORKSPACE/test_tune.conf
            val=$($OMPI_HOME/bin/mpirun -np 2 -tune $WORKSPACE/test_tune.conf $WORKSPACE/env_mpi | sed -n -e 's/^XXX_.*=//p' | sed -e ':a;N;$!ba;s/\n/+/g' | bc)
            # return (1+2+3+4+5)*2=30
            if [ $val -ne 30 ]; then
                if [ $ghprbTargetBranch == "mellanox-v1.8" ]; then
                    exit 1
                fi
            fi

            echo "-mca mca_base_env_list \"XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E\"" > $WORKSPACE/test_tune.conf
            val=$($OMPI_HOME/bin/mpirun -np 2 -tune $WORKSPACE/test_tune.conf  -mca mca_base_env_list "XXX_A=7;XXX_B=8"  $WORKSPACE/env_mpi | sed -n -e 's/^XXX_.*=//p' | sed -e ':a;N;$!ba;s/\n/+/g' | bc)
            # return (7+8+3+4+5)*2=54
            if [ $val -ne 54 ]; then
                if [ $ghprbTargetBranch == "mellanox-v1.8" ]; then
                    exit 1
                fi
            fi

            echo "-mca mca_base_env_list \"XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E\"" > $WORKSPACE/test_tune.conf
            echo "mca_base_env_list=XXX_A=7;XXX_B=8" > $WORKSPACE/test_amca.conf
            val=$($OMPI_HOME/bin/mpirun -np 2 -tune $WORKSPACE/test_tune.conf -am $WORKSPACE/test_amca.conf $WORKSPACE/env_mpi | sed -n -e 's/^XXX_.*=//p' | sed -e ':a;N;$!ba;s/\n/+/g' | bc)
            # return (1+2+3+4+5)*2=30
            if [ $val -ne 30 ]; then
                if [ $ghprbTargetBranch == "mellanox-v1.8" ]; then
                    exit 1
                fi
            fi

            echo "-mca mca_base_env_list \"XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E\"" > $WORKSPACE/test_tune.conf
            echo "mca_base_env_list=XXX_A=7;XXX_B=8" > $WORKSPACE/test_amca.conf
            val=$($OMPI_HOME/bin/mpirun -np 2 -tune $WORKSPACE/test_tune.conf -am $WORKSPACE/test_amca.conf -mca mca_base_env_list "XXX_A=9;XXX_B=10" $WORKSPACE/env_mpi | sed -n -e 's/^XXX_.*=//p' | sed -e ':a;N;$!ba;s/\n/+/g' | bc)
            # return (9+10+3+4+5)*2=62
            if [ $val -ne 62 ]; then
                if [ $ghprbTargetBranch == "mellanox-v1.8" ]; then
                    exit 1
                fi
            fi

            echo "-x XXX_A=6 -x XXX_C=7 -x XXX_D=8" > $WORKSPACE/test_tune.conf
            echo "-x XXX_B=9 -x XXX_E" > $WORKSPACE/test_tune2.conf
            val=$($OMPI_HOME/bin/mpirun -np 2 -tune $WORKSPACE/test_tune.conf:$WORKSPACE/test_tune2.conf $WORKSPACE/env_mpi | sed -n -e 's/^XXX_.*=//p' | sed -e ':a;N;$!ba;s/\n/+/g' | bc)
            # return (6+9+7+8+5)*2=70
            if [ $val -ne 70 ]; then
                if [ $ghprbTargetBranch == "mellanox-v1.8" ]; then
                    exit 1
                fi
            fi
        fi
    done

fi
