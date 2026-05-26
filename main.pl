#!/usr/bin/perl
use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request;
use JSON;
use File::Basename;
use Archive::Zip qw(:ERROR_CODES :CONSTANTS);
use Archive::Tar;
use File::Path qw(make_path remove_tree);
use YAML::XS;

use utf8;  # 处理源代码中的 UTF-8 字符
use open ':std', ':utf8';  # 设置默认的标准输入输出为 UTF-8

$ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0; # 先忽略 SSL 错误

sub getAppInfo {
    my ($appid) = @_;
    
    # 创建一个用户代理
    my $ua = LWP::UserAgent->new;
    my $url = 'https://appstore.api.lazycat.cloud/api/app/info';

    my $data = {
        pkgIds => [$appid],
    };
    
    my $request = HTTP::Request->new(POST => $url);
    $request->header('Content-Type' => 'application/json; charset=utf-8');
    $request->content(encode_json($data));

    my $response = $ua->request($request);

    if ($response->is_success) {
        my $json_response = decode_json($response->decoded_content);

        if ($json_response->{success}) {
            return $json_response->{data}[0];
        } else {
            warn "Error: $json_response->{message}\n";
            return undef;
        }
    } else {
        warn "HTTP Error: " . $response->status_line . "\n";
        return undef;
    }
}

sub downloadLpkFile {
    my ($url) = @_;
    
    my $ua = LWP::UserAgent->new;

    my $tmp_dir = 'tmp';
    make_path($tmp_dir) unless -d $tmp_dir;

    # my $file_name = basename($url);
    my $file_name = "./tmp/tmpfile.lpk";

    my $response = $ua->get($url, ':content_file' => $file_name);

    if ($response->is_success) {
        # print "下载成功: $file_name\n";
        return $file_name;
    } else {
        warn "下载失败: " . $response->status_line . "\n";
        return undef;
    }
}

sub unLpkFile {
    my ($file_path) = @_;

    my $tmp_dir = './tmp/content';
    remove_tree($tmp_dir) if -d $tmp_dir;
    make_path($tmp_dir);

    open my $fh, '<:raw', $file_path or do {
        warn "无法打开文件: $file_path: $!\n";
        return 0;
    };
    read $fh, my $magic, 4;
    close $fh;

    if ($magic eq "PK\x03\x04") {
        my $zip = Archive::Zip->new();
        my $status = eval { $zip->read($file_path) };

        if (defined $status && $status == AZ_OK) {
            $zip->extractTree('', $tmp_dir);
            return 1;
        }

        my $zip_error = $@ || (defined $status ? $status : 'unknown zip status');
        warn "解压 zip 失败: $zip_error\n";
        return 0;
    }

    my $tar = Archive::Tar->new();
    my $tar_ok = eval {
        $tar->read($file_path);

        for my $file ($tar->get_files) {
            my $target = "$tmp_dir/" . $file->full_path;
            my $target_dir = dirname($target);
            make_path($target_dir) unless -d $target_dir;
            $tar->extract_file($file->full_path, $target);
        }

        1;
    };

    if ($tar_ok) {
        return 1;
    }

    my $tar_error = $@ || 'unknown tar error';
    warn "解压 tar 失败: $tar_error\n";
    return 0;
}

sub parseYamlFile {
    my ($file_path) = @_;

    return undef unless -e $file_path;

    my $data = eval { YAML::XS::LoadFile($file_path) };
    if ($@) {
        warn "Failed to parse YAML file $file_path: $@";
        return undef;
    }

    return $data;
}

sub loadPackageData {
    my ($base_dir) = @_;

    my $manifest_file_path = -e "$base_dir/manifest.yml"
        ? "$base_dir/manifest.yml"
        : "$base_dir/lzc-manifest.yml";
    my $package_file_path = "$base_dir/package.yml";

    my $manifest_data = parseYamlFile($manifest_file_path);
    my $package_data = parseYamlFile($package_file_path);

    if (!$manifest_data && !$package_data) {
        warn "Failed to find manifest.yml, lzc-manifest.yml, or package.yml under $base_dir\n";
        return undef;
    }

    my $data = {};

    if ($manifest_data) {
        %{$data} = %{$manifest_data};
    }

    if ($package_data) {
        for my $key (keys %{$package_data}) {
            $data->{$key} = $package_data->{$key};
        }
    }

    return $data;
}

sub extractInfo {
    my ($data) = @_;
    my @results;
    my %seen;

    my $package = $data->{package};
    if (!defined $package && defined $data->{application}->{upstreams}) {
        for my $upstream (@{ $data->{application}->{upstreams} }) {
            my $backend = $upstream->{backend};
            if ($backend && $backend =~ m{^[a-z]+://[^.]+\.(.+)\.lzcapp(?::\d+)?$}) {
                $package = $1;
                last;
            }
        }
    }

    # 处理 route 部分
    if (defined $data->{application}->{routes}) {
        for my $route (@{ $data->{application}->{routes} }) {
            if ($route =~ m{^/(.*)=(http://(.*))}){
                my $host_info = $3;
                my ($service_name, $port) = split /:/, $host_info;

                if ($port) {
                    push @results, "${service_name}:${port}";
                }
            }
        }
    }

    # 处理 ingress
    if (defined $data->{application}->{ingress}) {
        for my $ingress (@{ $data->{application}->{ingress} }) {
            my $protocol = $ingress->{protocol};
            my $service = $ingress->{service};
            my $port = $ingress->{port};
            my $result = "${protocol}://${service}.${package}.lzcapp:${port}";
            push @results, $result unless $seen{$result}++;
        }
    }

    # 处理 upstreams
    if (defined $data->{application}->{upstreams}) {
        for my $upstream (@{ $data->{application}->{upstreams} }) {
            my $backend = $upstream->{backend};
            next unless $backend;

            if ($backend =~ m{^([a-z]+)://([^.]+)\.([^.]+(?:\.[^.]+)*)\.lzcapp:(\d+)(?:/.*)?$}) {
                my ($protocol, $service_name, $backend_package, $port) = ($1, $2, $3, $4);
                my $result = "${protocol}://${service_name}.${backend_package}.lzcapp:${port}";
                push @results, $result unless $seen{$result}++;
            }
        }
    }

    # 处理 services 部分
    if (defined $data->{services}) {
        for my $service_name (keys %{ $data->{services} }) {
            my $service = $data->{services}->{$service_name};

            my $result = "${service_name}.${package}.lzcapp:0";
            push @results, $result unless $seen{$result}++;
            # if ($service->{command} =~ /:(\d+)/) {
            #     my $port = $1;
            # } else {
            #     push @results, "${service_name}.${package}.lzcapp:0";
            # }
        }
    }

    return @results;
}


if (@ARGV != 1) {
    die "Usage: perl main.pl <appid>/<path>\n";
}

my ($appid_or_path) = $ARGV[0];
if (!$appid_or_path) {
    print "[failed] 请输入正确的 appid 或文件路径, 示例: cloud.lazycat.app.forwar 或 ./demo.lpk\n";
    exit 1;
}

# my $appid_or_path = "cloud.lazycat.app.forward";  # 替换为实际的 appid
my $file_path = $appid_or_path;
if (-e $appid_or_path) {
    print "开始解析 $appid_or_path 文件。\n";
} else {
    my $appid = $appid_or_path;
    my $app_info = getAppInfo($appid);
    if (!$app_info) {
        print "没有获取到 appid:$appid 应用信息。\n";
        exit 1;
    }
    # my $apk_url = "https://repo.lazycat.cloud$app_info->{pkgPath}";
    my $apk_url = "https://dl.lazycat.cloud/appstore/lpks$app_info->{pkgPath}";

    print "name: $app_info->{name}\n";
    print "appid: $app_info->{pkgId}\n";
    print "version: $app_info->{version}\n";
    print "url: $apk_url\n";

    # 下载 lpk 文件
    $file_path = downloadLpkFile($apk_url);
    if (!$file_path) {
        print "[failed] 下载包失败\n";
        exit 1;
    }
}

# 解压 lpk 文件
if(!unLpkFile($file_path)) {
    print "[failed] 解压包失败\n";
    exit 1;
}

my $parsed_data = loadPackageData('tmp/content');

if (!$parsed_data) {
    print "[failed] 解析包数据失败\n";
    exit 1;
}

print "subdomain: https://$parsed_data->{application}->{subdomain}.boxname.heiyu.space\n";

# 读取服务信息
my @result_strings = extractInfo($parsed_data);
print "\n[Success] LzcApp 可转发的服务列表:\n";
print "$_\n" for @result_strings;
print "\n"
