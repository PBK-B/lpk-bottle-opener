#!/usr/bin/perl
use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request;
use JSON;
use File::Basename;
use Archive::Zip qw(:ERROR_CODES :CONSTANTS);
use File::Path qw(make_path);
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
    make_path($tmp_dir) unless -d $tmp_dir;

    my $zip = Archive::Zip->new();
    my $status = $zip->read($file_path);

    if ($status == AZ_OK) {
        $zip->extractTree('', $tmp_dir);
        # print "解压成功到: $tmp_dir\n";
        return 1;
    } else {
        warn "解压失败: " . Archive::Zip::getStatusString($status) . "\n";
        return 0;
    }
}

sub parseManifestFile {
    my ($file_path) = @_;

    my $data = YAML::XS::LoadFile($file_path);

    if (defined $data) {
        return $data;
    } else {
        warn "Failed to parse YAML content.";
        return undef;
    }
}

sub extractInfo {
    my ($data) = @_;
    my @results;

    my $package = $data->{package};

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
            push @results, "${protocol}://${service}.${package}.lzcapp:${port}";
        }
    }

    # 处理 services 部分
    if (defined $data->{services}) {
        for my $service_name (keys %{ $data->{services} }) {
            my $service = $data->{services}->{$service_name};

            push @results, "${service_name}.${package}.lzcapp:0";
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

my $manifest_file_path = 'tmp/content/manifest.yml';
my $parsed_data = parseManifestFile($manifest_file_path);

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