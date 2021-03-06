#!/bin/bash
# set -e

JENKINS_FILE=$(ls -1 _build/jenkins/ | head -1)
JENKINS_PHP=$(cat "_build/jenkins/${JENKINS_FILE}" | awk -v FS="(php|-sp)" '{print $2}' | grep '[0-9]' | head -1)

echo "Found PHP version ${JENKINS_PHP} from jenkins file..."

if [ -z "$JENKINS_PHP" ]
then
  PHP_BIN="/phpfarm/inst/bin/php-${INPUT_PHP_VERSION}"
else
  PHP_BIN="/phpfarm/inst/bin/php-${JENKINS_PHP}"
fi

ARGUMENTS=$(echo ${INPUT_ARGUMENTS} | sed 's/m2\/app/app/g' | sed 's/  */ /g') #change paths from m2/app... to app...
ARGUMENTS=$(echo ${ARGUMENTS} | sed 's/public\/app/app/g' | sed 's/  */ /g') #change paths from public/app... to app...
if [[ $INPUT_FULL_SCAN == 'false' ]]
then
  echo "Removing none org namespace (${INPUT_ORG_NAMESPACE}) changes..."
  ARGUMENTS=$(echo $ARGUMENTS | sed 's/[\ ]/\n/g' | sed "/\/code\/${INPUT_ORG_NAMESPACE}\//!s/.*/ /" | tr '\n' ' ')
fi

if [ -z "$(ls)" ]; then
  echo "No code have been found.  Did you checkout with «actions/checkout» ?"
  exit 1
fi

PHP_FULL_VERSION=$($PHP_BIN -r 'echo phpversion();')
echo "PHP Version : ${PHP_FULL_VERSION}"

echo "Finding magento root path..."
BIN_MAGENTO_PATH=$(find . -name 'magento' -maxdepth 3 | grep -m1 'bin/magento')
MAGENTO_ROOT_PATH="$(dirname $BIN_MAGENTO_PATH)/../"

echo "Changing dir to magento root path ${MAGENTO_ROOT_PATH}"
cd $MAGENTO_ROOT_PATH

echo "Installing composer..."
$PHP_BIN -r "copy('https://getcomposer.org/composer-1.phar', 'composer.phar');"

HAS_MAGENTO_COMPOSER_KEYS=$(cat ./auth.json | grep "repo.magento.com")
if [[ -z $HAS_MAGENTO_COMPOSER_KEYS ]]
then
  echo "No repo.magento.com creds found in auth.json."
  $PHP_BIN -d memory_limit=-1 composer.phar config http-basic.repo.magento.com $INPUT_MAGENTO_COMPOSER_USERNAME $INPUT_MAGENTO_COMPOSER_PASSWORD
fi

echo "Temporarily killing composer as not needed..."
mv composer.json composer.json.bk
mv composer.lock composer.lock.bk

echo "Installing hirak/prestissimo..."
$PHP_BIN -d memory_limit=-1 composer.phar global require hirak/prestissimo --quiet

echo "Installing magento/magento-coding-standard..."
$PHP_BIN -d memory_limit=-1 composer.phar require magento/magento-coding-standard:* --quiet --ignore-platform-reqs

echo "Installing slevomat/coding-standard..."
$PHP_BIN -d memory_limit=-1 composer.phar require slevomat/coding-standard:* --quiet

echo "Setting up PHPCS standards..."
$PHP_BIN ./vendor/bin/phpcs --config-set installed_paths ../../magento/magento-coding-standard/,../../slevomat/coding-standard/

echo "Moving in custom phpcs rulesets..."
cp /phpcs.xml .
cp -R /Sniffs/Custom ./vendor/magento/magento-coding-standard/Magento2/Sniffs/

echo "## Running PHPCBF with arguments «${ARGUMENTS}»"
PHPCBF_OUTPUT=$($PHP_BIN -d memory_limit=-1 ./vendor/bin/phpcbf --standard=phpcs.xml ${ARGUMENTS})
PHPCBF_FIXED_CHECK=$(echo $PHPCBF_OUTPUT | grep "No fixable errors were found")
PHPCBF_OUTPUT="${PHPCBF_OUTPUT//'%'/'%25'}"
PHPCBF_OUTPUT="${PHPCBF_OUTPUT//$'\n'/'%0A'}"
PHPCBF_OUTPUT="${PHPCBF_OUTPUT//$'\r'/'%0D'}"
echo "::set-output name=phpcbf_output::$PHPCBF_OUTPUT"

FILE_CHECKED=$(echo ${INPUT_ARGUMENTS} | sed 's/  */ /g')
echo "::set-output name=files_checked::$FILE_CHECKED"

if [[ "$PHPCBF_FIXED_CHECK" == *"No fixable errors were found"* ]]
then
  echo "::set-output name=phpcbf_fixed_anything::false"
else
  echo "::set-output name=phpcbf_fixed_anything::true"
fi

echo "## Running PHPCS with arguments «${ARGUMENTS}»"
PHPCS_OUTPUT=$($PHP_BIN -d memory_limit=-1 ./vendor/bin/phpcs --standard=phpcs.xml ${ARGUMENTS})
PHPCS_OUTPUT="${PHPCS_OUTPUT//'%'/'%25'}"
PHPCS_OUTPUT="${PHPCS_OUTPUT//$'\n'/'%0A'}"
PHPCS_OUTPUT="${PHPCS_OUTPUT//$'\r'/'%0D'}"
echo "::set-output name=phpcs_output::$PHPCS_OUTPUT"
PHPCS_ERROR_COUNT=$(echo $PHPCS_OUTPUT | awk -v FS="(FOUND|ERRORS)" '{print $2}' | grep '[0-9]' | sed 's/ //g')
PHPCS_WARNING_COUNT=$(echo $PHPCS_OUTPUT | awk -v FS="(AND|WARNINGS)" '{print $2}' | grep '[0-9]' | sed 's/ //g')

if [[ "$PHPCS_ERROR_COUNT" == "0" ]]
then
  echo "::set-output name=phpcs_has_errors::false"
else
  echo "::set-output name=phpcs_has_errors::true"
fi

if [[ "$PHPCS_WARNING_COUNT" == "0" ]]
then
  echo "::set-output name=phpcs_has_warnings::false"
else
  echo "::set-output name=phpcs_has_warnings::true"
fi

#annotatate files in PR
cp /problem-matcher.json .
echo "::add-matcher::$(pwd)/problem-matcher.json"
$PHP_BIN -d memory_limit=-1 ./vendor/bin/phpcs --report=checkstyle --standard=phpcs.xml ${ARGUMENTS}

echo "Reverting the killing of composer as not needed..."
mv composer.json.bk composer.json
mv composer.lock.bk composer.lock
